using Dapper;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;
using PPMS.Application.Interfaces;

namespace PPMS.Infrastructure.Persistence;

/// <summary>Roz ke backup email ki setting / claim / natija - AppSettings (Section BA).</summary>
public sealed class BackupEmailRepository(IOptions<DatabaseOptions> options) : IBackupEmailRepository
{
    private readonly DatabaseOptions _options = options.Value;

    public async Task<BackupEmailSettings> GetAsync(CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        return await connection.QuerySingleAsync<BackupEmailSettings>(new CommandDefinition(
            "PUMP.sp_BackupEmail_Get", commandType: System.Data.CommandType.StoredProcedure, cancellationToken: cancellationToken));
    }

    public async Task<BackupEmailSettings> SaveAsync(bool enabled, string? emailTo, int hour, long? byUserId, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        return await connection.QuerySingleAsync<BackupEmailSettings>(new CommandDefinition(
            "PUMP.sp_BackupEmail_Save",
            new { Enabled = enabled, EmailTo = emailTo, Hour = hour, UserId = byUserId },
            commandType: System.Data.CommandType.StoredProcedure, cancellationToken: cancellationToken));
    }

    public async Task<bool> ClaimAsync(DateOnly today, bool force, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        return await connection.QuerySingleAsync<bool>(new CommandDefinition(
            "PUMP.sp_BackupEmail_Claim",
            new { Today = today.ToDateTime(TimeOnly.MinValue), Force = force },
            commandType: System.Data.CommandType.StoredProcedure, cancellationToken: cancellationToken));
    }

    public async Task SetResultAsync(bool ok, DateOnly today, string status, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        await connection.ExecuteAsync(new CommandDefinition(
            "PUMP.sp_BackupEmail_SetResult",
            new { Ok = ok, Today = today.ToDateTime(TimeOnly.MinValue), Status = status },
            commandType: System.Data.CommandType.StoredProcedure, cancellationToken: cancellationToken));
    }
}
