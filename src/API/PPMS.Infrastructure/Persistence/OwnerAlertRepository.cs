using Dapper;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;
using PPMS.Application.Interfaces;

namespace PPMS.Infrastructure.Persistence;

public sealed class OwnerAlertRepository(IOptions<DatabaseOptions> options) : IOwnerAlertRepository
{
    private readonly DatabaseOptions _options = options.Value;

    public async Task<OwnerAlertTarget?> GetTargetAsync(long ownerId, string alertKey, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        return await connection.QueryFirstOrDefaultAsync<OwnerAlertTarget>(
            sql: "PUMP.sp_Notification_GetOwnerTarget",
            param: new { OwnerId = ownerId, AlertKey = alertKey },
            commandType: System.Data.CommandType.StoredProcedure);
    }

    public async Task<IReadOnlyList<OwnerAlertSetting>> ListAsync(long ownerId, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        var rows = await connection.QueryAsync<OwnerAlertSetting>(
            sql: "PUMP.sp_OwnerAlert_List",
            param: new { OwnerId = ownerId },
            commandType: System.Data.CommandType.StoredProcedure);
        return rows.AsList();
    }

    public async Task SaveAsync(long ownerId, string alertKey, bool isEnabled, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        await connection.ExecuteAsync(
            sql: "PUMP.sp_OwnerAlert_Save",
            param: new { OwnerId = ownerId, AlertKey = alertKey, IsEnabled = isEnabled },
            commandType: System.Data.CommandType.StoredProcedure);
    }

    public async Task SaveMobileAsync(long ownerId, string? mobile, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        await connection.ExecuteAsync(
            sql: "PUMP.sp_OwnerAlert_SaveMobile",
            param: new { OwnerId = ownerId, Mobile = mobile },
            commandType: System.Data.CommandType.StoredProcedure);
    }
}
