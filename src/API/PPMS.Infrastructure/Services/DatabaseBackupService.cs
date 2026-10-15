using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using PPMS.Infrastructure.Persistence;

namespace PPMS.Infrastructure.Services;

public sealed class BackupOptions
{
    public const string SectionName = "Backup";

    /// <summary>Production par ise true karna hai. Development me band rehta hai.</summary>
    public bool Enabled { get; set; }

    /// <summary>
    /// Folder jahan .bak file banegi. Ye SQL SERVER ki machine ka path hai, API ki
    /// nahi — BACKUP DATABASE server par chalti hai. Alag machine par SQL ho to
    /// wahan ka path (ya share) dena hoga.
    /// </summary>
    public string Path { get; set; } = @"C:\PPMS-Backups";

    /// <summary>Din me kis ghante par (0-23). Default 2 baje raat — pump band rehta hai.</summary>
    public int Hour { get; set; } = 2;

    /// <summary>Itne din purani backup file hata di jaati hai.</summary>
    public int RetentionDays { get; set; } = 14;
}

/// <summary>
/// Roz apne aap database ka backup leta hai.
///
/// SQL Agent se kyun nahi: SQL Express aur LocalDB dono me SQL Agent hota hi nahi,
/// aur pan-India me bahut se pump chhote server/Express par chalenge. App ke andar
/// rakhne se har jagah ek jaisa chalega, aur backup ka log bhi AuditLog me aa jaata
/// hai — puchne par bataya ja sake ki aakhri backup kab hua.
/// </summary>
public sealed class DatabaseBackupService(
    IOptions<BackupOptions> backupOptions,
    IOptions<DatabaseOptions> dbOptions,
    ILogger<DatabaseBackupService> logger) : BackgroundService
{
    private readonly BackupOptions _backup = backupOptions.Value;
    private readonly DatabaseOptions _db = dbOptions.Value;

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        if (!_backup.Enabled)
        {
            logger.LogInformation("Auto-backup band hai (Backup:Enabled = false).");
            return;
        }

        logger.LogInformation(
            "Auto-backup chalu — roz {Hour}:00 baje, {Days} din tak rakhi jayegi, folder: {Path}",
            _backup.Hour, _backup.RetentionDays, _backup.Path);

        while (!stoppingToken.IsCancellationRequested)
        {
            var wait = TimeUntilNextRun();
            try
            {
                await Task.Delay(wait, stoppingToken);
            }
            catch (OperationCanceledException)
            {
                return;   // app band ho raha hai
            }

            try
            {
                await RunBackupAsync(stoppingToken);
            }
            catch (Exception ex)
            {
                // Backup fail hone se API band nahi honi chahiye — kal phir koshish hogi.
                logger.LogError(ex, "Auto-backup fail ho gaya.");
            }
        }
    }

    private TimeSpan TimeUntilNextRun()
    {
        var now = DateTime.Now;
        var next = new DateTime(now.Year, now.Month, now.Day, Math.Clamp(_backup.Hour, 0, 23), 0, 0);
        if (next <= now)
        {
            next = next.AddDays(1);
        }

        return next - now;
    }

    private async Task RunBackupAsync(CancellationToken cancellationToken)
    {
        var builder = new SqlConnectionStringBuilder(_db.ConnectionString);
        var dbName = builder.InitialCatalog;

        if (string.IsNullOrWhiteSpace(dbName))
        {
            logger.LogWarning("Connection string me database ka naam nahi mila — backup nahi liya.");
            return;
        }

        var fileName = $"{dbName}-{DateTime.Now:yyyyMMdd-HHmm}.bak";
        var fullPath = System.IO.Path.Combine(_backup.Path, fileName);

        await using var connection = new SqlConnection(_db.ConnectionString);
        await connection.OpenAsync(cancellationToken);

        // Folder na ho to BACKUP fail ho jaati hai. Server par bana lete hain
        // (xp_create_subdir SQL Server ki machine par folder banati hai).
        await using (var mkdir = connection.CreateCommand())
        {
            mkdir.CommandText = "EXEC master.dbo.xp_create_subdir @p";
            mkdir.Parameters.AddWithValue("@p", _backup.Path);
            try
            {
                await mkdir.ExecuteNonQueryAsync(cancellationToken);
            }
            catch (SqlException ex)
            {
                // Permission na ho to bhi aage badho — folder pehle se ho sakta hai.
                logger.LogDebug(ex, "xp_create_subdir nahi chali (folder shayad pehle se hai).");
            }
        }

        await using (var backup = connection.CreateCommand())
        {
            // Database ka naam identifier hai, isliye QUOTENAME se bracket lagate hain;
            // file path parameter se jaata hai. Dono milakar injection ka raasta band.
            backup.CommandText = @"
DECLARE @sql NVARCHAR(MAX) =
    N'BACKUP DATABASE ' + QUOTENAME(@dbName) +
    N' TO DISK = @disk WITH INIT, COMPRESSION, NAME = ''PPMS auto backup''';
BEGIN TRY
    EXEC sp_executesql @sql, N'@disk NVARCHAR(500)', @disk = @path;
END TRY
BEGIN CATCH
    /* COMPRESSION har edition me nahi hoti (Express me nahi). Uske bina dobara. */
    SET @sql = N'BACKUP DATABASE ' + QUOTENAME(@dbName) +
               N' TO DISK = @disk WITH INIT, NAME = ''PPMS auto backup''';
    EXEC sp_executesql @sql, N'@disk NVARCHAR(500)', @disk = @path;
END CATCH";
            backup.Parameters.AddWithValue("@dbName", dbName);
            backup.Parameters.AddWithValue("@path", fullPath);
            backup.CommandTimeout = 60 * 30;   // bade DB par 30 minute tak
            await backup.ExecuteNonQueryAsync(cancellationToken);
        }

        logger.LogInformation("Backup ban gaya: {File}", fullPath);

        await using (var audit = connection.CreateCommand())
        {
            audit.CommandText = "PUMP.sp_Audit_Log";
            audit.CommandType = System.Data.CommandType.StoredProcedure;
            audit.Parameters.AddWithValue("@OwnerId", DBNull.Value);
            audit.Parameters.AddWithValue("@PumpId", DBNull.Value);
            audit.Parameters.AddWithValue("@UserId", DBNull.Value);
            audit.Parameters.AddWithValue("@EntityName", "Database");
            audit.Parameters.AddWithValue("@EntityId", 0);
            audit.Parameters.AddWithValue("@Action", "AUTO_BACKUP");
            audit.Parameters.AddWithValue("@Reason", fileName);
            await audit.ExecuteNonQueryAsync(cancellationToken);
        }

        CleanOldBackups();
    }

    /// <summary>
    /// Purani file hatana zaroori hai, warna mahine bhar me disk bhar jaati hai aur
    /// tab NAYA backup bhi fail hone lagta hai — yaani backup hai bhi to kaam ka nahi.
    /// </summary>
    private void CleanOldBackups()
    {
        try
        {
            if (!Directory.Exists(_backup.Path))
            {
                // SQL doosri machine par ho to API ko folder dikhega hi nahi — koi baat nahi.
                return;
            }

            var cutoff = DateTime.Now.AddDays(-Math.Max(1, _backup.RetentionDays));

            foreach (var file in Directory.GetFiles(_backup.Path, "*.bak"))
            {
                if (File.GetLastWriteTime(file) < cutoff)
                {
                    File.Delete(file);
                    logger.LogInformation("Purani backup hata di: {File}", System.IO.Path.GetFileName(file));
                }
            }
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "Purani backup hatate waqt dikkat aayi.");
        }
    }
}
