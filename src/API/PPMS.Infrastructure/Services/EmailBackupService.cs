using System.IO.Compression;
using System.Text;
using System.Text.Json;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using PPMS.Application.Interfaces;
using PPMS.Infrastructure.Persistence;

namespace PPMS.Infrastructure.Services;

/// <summary>
/// Roz ka backup email par (Section BA). Live shared server par DB user ko BACKUP DATABASE ki ijaazat
/// nahi - DatabaseBackupService ka .bak wahan kabhi nahi bana. Ye sirf PADHTA hai: poore DB ki ek SQL
/// file (structure + saara data + index + foreign key + procedure / function) zip me, Gmail se.
/// Khaali database par wo file chalao to poora DB wapas.
/// </summary>
public sealed class BackupEmailRunner(
    IOptions<DatabaseOptions> dbOptions,
    IBackupEmailRepository repository,
    IEmailSender email,
    ILogger<BackupEmailRunner> logger) : IBackupEmailRunner
{
    /// <summary>Gmail 25 MB tak; attachment base64 me ~33% badhta hai - 18 MB ka zip hi surakshit.</summary>
    private const long MaxZipBytes = 18L * 1024 * 1024;

    public async Task<BackupRunResult?> RunAsync(bool force, CancellationToken cancellationToken = default)
    {
        var settings = await repository.GetAsync(cancellationToken);
        var nowIndia = IndiaTime.Now;
        var today = DateOnly.FromDateTime(nowIndia);

        if (!force && (!settings.Enabled || nowIndia.Hour < settings.Hour))
        {
            return null;
        }

        if (!email.IsConfigured)
        {
            // Claim nahi kiya - Email setting aate hi agli baar khud chal jaayega.
            return force ? new BackupRunResult(false, "Email is not set up on the server.") : null;
        }

        if (!await repository.ClaimAsync(today, force, cancellationToken))
        {
            return null;   // aaj ka ja chuka / ghante bhar me koshish ho chuki / doosri copy bhej rahi hai
        }

        var to = string.IsNullOrWhiteSpace(settings.EmailTo) ? email.FromAddress! : settings.EmailTo!;
        try
        {
            var (zip, tables, rows) = await BuildZipAsync(nowIndia, cancellationToken);
            var sizeKb = zip.Length / 1024;

            if (zip.Length > MaxZipBytes)
            {
                var big = $"Backup is {sizeKb / 1024} MB - too big for email. Ask the developer for another way.";
                await email.SendAsync(to, $"PPMS backup {nowIndia:dd-MMM-yyyy} - too big", big, cancellationToken);
                await repository.SetResultAsync(false, today, big, cancellationToken);
                logger.LogError("Daily backup too big for email: {Kb} KB", sizeKb);
                return new BackupRunResult(false, big);
            }

            var fileName = $"PPMS-backup-{nowIndia:yyyy-MM-dd-HHmm}.zip";
            var body =
                $"PPMS ka roz ka backup - {nowIndia:dd-MMM-yyyy hh:mm tt} (India).\n" +
                $"{tables} tables, {rows:N0} rows, {sizeKb:N0} KB.\n\n" +
                "Is file me poora database hai - saari tables (structure + data), procedures, functions.\n" +
                "Ise sambhal ke rakhiye aur kisi ko mat bhejiye.\n\n" +
                "Wapas laana ho: naya khaali database banaiye, zip ki PPMS-full-backup.sql usi par chalaiye:\n" +
                "  sqlcmd -S <server> -d <naya_db> -E -I -i PPMS-full-backup.sql\n\n" +
                $"Daily PPMS backup - full database as one SQL script ({tables} tables, {rows:N0} rows).";

            var sent = await email.SendWithAttachmentAsync(to, $"PPMS backup {nowIndia:dd-MMM-yyyy}", body, fileName, zip, cancellationToken);
            var status = sent
                ? $"Sent {nowIndia:dd-MMM-yyyy HH:mm} to {to} - {tables} tables, {rows:N0} rows, {sizeKb:N0} KB"
                : $"Email failed {nowIndia:dd-MMM-yyyy HH:mm} - see server log. Will try again in an hour.";
            await repository.SetResultAsync(sent, today, status, cancellationToken);

            if (sent) logger.LogInformation("Daily backup emailed: {Status}", status);
            else logger.LogError("Daily backup email failed.");
            return new BackupRunResult(sent, status);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            logger.LogError(ex, "Daily backup could not be made.");
            var status = $"Backup failed {nowIndia:dd-MMM-yyyy HH:mm}: {ex.GetType().Name}. Will try again in an hour.";
            await repository.SetResultAsync(false, today, status, CancellationToken.None);
            return new BackupRunResult(false, status);
        }
    }

    /// <summary>Zip: PPMS-full-backup.sql (DatabaseScripter - koi table nahi chhoot-ti) + manifest.json.</summary>
    private async Task<(byte[] Zip, int Tables, long Rows)> BuildZipAsync(DateTime nowIndia, CancellationToken cancellationToken)
    {
        await using var connection = new SqlConnection(dbOptions.Value.ConnectionString);
        await connection.OpenAsync(cancellationToken);

        using var buffer = new MemoryStream();
        DatabaseScripter.Summary summary;
        using (var zip = new ZipArchive(buffer, ZipArchiveMode.Create, leaveOpen: true))
        {
            var entry = zip.CreateEntry("PPMS-full-backup.sql", CompressionLevel.Optimal);
            await using (var es = entry.Open())
            // BOM ke saath - sqlcmd / SSMS Hindi naam sahi padhein.
            await using (var sw = new StreamWriter(es, new UTF8Encoding(encoderShouldEmitUTF8Identifier: true)))
            {
                summary = await new DatabaseScripter(connection).WriteAsync(sw, cancellationToken);
                await sw.FlushAsync();
            }

            var m = zip.CreateEntry("manifest.json", CompressionLevel.Optimal);
            await using var ms = m.Open();
            await JsonSerializer.SerializeAsync(ms, new
            {
                App = "PPMS",
                Database = connection.Database,
                CreatedIndiaTime = nowIndia.ToString("yyyy-MM-dd HH:mm:ss"),
                Restore = "Naya khaali database banao, phir: sqlcmd -S <server> -d <naya_db> -E -I -i PPMS-full-backup.sql",
                summary.Tables,
                summary.Rows,
                ProceduresAndFunctions = summary.Modules,
                PerTable = summary.PerTable.Select(x => new { x.Table, x.Rows })
            }, new JsonSerializerOptions { WriteIndented = true }, cancellationToken);
        }

        return (buffer.ToArray(), summary.Tables, summary.Rows);
    }
}

/// <summary>India ka samay - shared server ki ghadi aksar UTC ya kahin aur ki hoti hai.</summary>
internal static class IndiaTime
{
    private static readonly TimeZoneInfo? Zone = Find("India Standard Time") ?? Find("Asia/Kolkata");

    public static DateTime Now => Zone is null
        ? DateTime.UtcNow.AddMinutes(330)
        : TimeZoneInfo.ConvertTimeFromUtc(DateTime.UtcNow, Zone);

    private static TimeZoneInfo? Find(string id)
    {
        try { return TimeZoneInfo.FindSystemTimeZoneById(id); }
        catch (Exception) { return null; }
    }
}

/// <summary>
/// Har 10 minute dekhta hai: aaj ka backup gaya? Shared server par app raat ko so jaati hai, isliye
/// "theek 3 baje" nahi - tay ghante ke baad jab bhi app jaage (subah pehla login bhi chalega).
/// </summary>
public sealed class EmailBackupService(IServiceScopeFactory scopes, ILogger<EmailBackupService> logger) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        // App chalu hote hi DB / migration ke saath na takraaye.
        try { await Task.Delay(TimeSpan.FromMinutes(2), stoppingToken); }
        catch (OperationCanceledException) { return; }

        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                using var scope = scopes.CreateScope();
                var runner = scope.ServiceProvider.GetRequiredService<IBackupEmailRunner>();
                await runner.RunAsync(force: false, stoppingToken);
            }
            catch (OperationCanceledException) { return; }
            catch (SqlException ex)
            {
                // Section BA abhi DB me nahi (naya build pehle) - chup-chaap, agli baar phir.
                logger.LogDebug(ex, "Backup email check skipped (database).");
            }
            catch (Exception ex)
            {
                logger.LogError(ex, "Backup email check failed.");
            }

            try { await Task.Delay(TimeSpan.FromMinutes(10), stoppingToken); }
            catch (OperationCanceledException) { return; }
        }
    }
}
