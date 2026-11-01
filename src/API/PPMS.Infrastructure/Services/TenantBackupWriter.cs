using System.Text;
using System.Text.Json;
using Microsoft.Extensions.Options;
using PPMS.Application.Features.Owners;

namespace PPMS.Infrastructure.Services;

public sealed class TenantBackupOptions
{
    public const string SectionName = "TenantBackup";

    /// <summary>
    /// "Poora mitao" se pehle tenant ka data yahan JSON file me jaata hai. Ye API ki machine ka
    /// path hai (file API likhti hai, SQL Server nahi). Deploy me ye folder mitna nahi chahiye -
    /// isliye app ke folder ke bahar.
    /// </summary>
    public string Path { get; set; } = @"C:\PPMS-Backups\tenant-deletes";
}

/// <summary>
/// Tenant ka saara data ek JSON file me (Section AX). sp_Owner_Export har table ka data pehle se
/// JSON array me deta hai - yahan bas use ek file me jodna hai, dobara parse nahi.
/// </summary>
public sealed class TenantBackupWriter(IOptions<TenantBackupOptions> options) : ITenantBackupWriter
{
    private readonly TenantBackupOptions _options = options.Value;

    public async Task<string> WriteAsync(long ownerId, string ownerName, IReadOnlyList<TenantExportTableDto> tables, CancellationToken cancellationToken = default)
    {
        // Shared server (Plesk) par C:\ me likhne ki ijaazat nahi hoti - "App_Data\tenant-deletes" jaisa
        // chhota raasta app ke apne folder se juda maana jaata hai.
        var folder = System.IO.Path.IsPathRooted(_options.Path)
            ? _options.Path
            : System.IO.Path.Combine(AppContext.BaseDirectory, _options.Path);
        Directory.CreateDirectory(folder);

        var file = System.IO.Path.Combine(
            folder,
            $"tenant-{ownerId}-{SafeName(ownerName)}-{DateTime.Now:yyyyMMdd-HHmmss}.json");

        // CreateNew - pehle se file ho to purani par likhna nahi.
        await using var stream = new FileStream(file, FileMode.CreateNew, FileAccess.Write);
        await stream.WriteAsync(ToJson(ownerId, ownerName, tables), cancellationToken);
        await stream.FlushAsync(cancellationToken);
        return file;
    }

    public byte[] ToJson(long ownerId, string ownerName, IReadOnlyList<TenantExportTableDto> tables)
    {
        using var buffer = new MemoryStream();
        using (var w = new Utf8JsonWriter(buffer))
        {
            w.WriteStartObject();
            w.WriteNumber("ownerId", ownerId);
            w.WriteString("ownerName", ownerName);
            w.WriteString("exportedOn", DateTime.Now);
            w.WriteString("note", "PPMS tenant backup - every table of this tenant, as stored in the database.");
            w.WriteStartObject("tables");
            foreach (var t in tables)
            {
                w.WriteStartObject(t.TableName);
                w.WriteNumber("rows", t.RowsCount);
                w.WritePropertyName("data");
                w.WriteRawValue(string.IsNullOrWhiteSpace(t.Data) ? "[]" : t.Data, skipInputValidation: false);
                w.WriteEndObject();
            }
            w.WriteEndObject();
            w.WriteEndObject();
        }

        return buffer.ToArray();
    }

    private static string SafeName(string name)
    {
        var sb = new StringBuilder();
        foreach (var ch in name)
        {
            sb.Append(char.IsLetterOrDigit(ch) && ch < 128 ? ch : '-');
        }

        var safe = sb.ToString().Trim('-');
        return safe.Length == 0 ? "tenant" : safe.Length > 40 ? safe[..40] : safe;
    }
}
