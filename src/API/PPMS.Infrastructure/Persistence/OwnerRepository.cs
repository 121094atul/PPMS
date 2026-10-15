using Dapper;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;
using PPMS.Application.Features.Owners;
using System.Data;

namespace PPMS.Infrastructure.Persistence;

public sealed class OwnerRepository(IOptions<DatabaseOptions> options) : IOwnerRepository
{
    private readonly DatabaseOptions _options = options.Value;

    public async Task<IReadOnlyList<OwnerDto>> GetAllAsync(CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        var items = await connection.QueryAsync<OwnerDto>(
            sql: "PUMP.sp_Owner_GetList",
            commandType: CommandType.StoredProcedure);
        return items.ToList();
    }

    public async Task<long> SaveAsync(string name, string adminUsername, string adminPasswordHash, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        var result = await connection.QuerySingleAsync<long>(
            sql: "PUMP.sp_Owner_Create",
            param: new { Name = name, AdminUsername = adminUsername, AdminPasswordHash = adminPasswordHash },
            commandType: CommandType.StoredProcedure);
        return result;
    }

    public async Task ToggleStatusAsync(long ownerId, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        await connection.ExecuteAsync(
            sql: "PUMP.sp_Owner_ToggleStatus",
            param: new { OwnerId = ownerId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task ExtendTrialAsync(long ownerId, DateTime newValidUpto, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        await connection.ExecuteAsync(
            sql: "PUMP.sp_Owner_ExtendTrial",
            param: new { OwnerId = ownerId, NewValidUpto = newValidUpto },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<IReadOnlyList<TenantUserDto>> GetUsersAsync(long ownerId, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        var rows = await connection.QueryAsync<TenantUserDto>(
            sql: "PUMP.sp_Owner_GetUsers",
            param: new { OwnerId = ownerId },
            commandType: CommandType.StoredProcedure);

        return rows.AsList();
    }
}
