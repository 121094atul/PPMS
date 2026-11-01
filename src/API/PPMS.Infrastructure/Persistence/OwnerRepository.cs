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

    // ---- Section AX ----

    public async Task<IReadOnlyList<OwnerPageRowDto>> GetPageAsync(string? search, string? status, string? sort, int pageNumber, int pageSize, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        var rows = await connection.QueryAsync<OwnerPageRowDto>(new CommandDefinition(
            "PUMP.sp_Owner_GetPage",
            new { Search = search, Status = status, Sort = sort, PageNumber = pageNumber, PageSize = pageSize },
            commandType: CommandType.StoredProcedure,
            cancellationToken: cancellationToken));
        return rows.AsList();
    }

    public async Task<OwnerStatusCountsDto> GetStatusCountsAsync(CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        return await connection.QuerySingleAsync<OwnerStatusCountsDto>(new CommandDefinition(
            "PUMP.sp_Owner_StatusCounts",
            commandType: CommandType.StoredProcedure,
            cancellationToken: cancellationToken));
    }

    public async Task SetArchivedAsync(long ownerId, bool archive, long? byUserId, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        await connection.ExecuteAsync(new CommandDefinition(
            "PUMP.sp_Owner_SetArchived",
            new { OwnerId = ownerId, Archive = archive, ByUserId = byUserId },
            commandType: CommandType.StoredProcedure,
            cancellationToken: cancellationToken));
    }

    public async Task<IReadOnlyList<TenantExportTableDto>> ExportAsync(long ownerId, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        var rows = await connection.QueryAsync<TenantExportTableDto>(new CommandDefinition(
            "PUMP.sp_Owner_Export",
            new { OwnerId = ownerId },
            commandType: CommandType.StoredProcedure,
            commandTimeout: 300,
            cancellationToken: cancellationToken));
        return rows.AsList();
    }

    public async Task CheckPurgeAsync(long ownerId, string confirmName, long? byUserId, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        await connection.ExecuteAsync(new CommandDefinition(
            "PUMP.sp_Owner_Purge",
            new { OwnerId = ownerId, ConfirmName = confirmName, ByUserId = byUserId, CheckOnly = true },
            commandType: CommandType.StoredProcedure,
            cancellationToken: cancellationToken));
    }

    public async Task<IReadOnlyList<TenantPurgeRowDto>> PurgeAsync(long ownerId, string confirmName, long? byUserId, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        var rows = await connection.QueryAsync<TenantPurgeRowDto>(new CommandDefinition(
            "PUMP.sp_Owner_Purge",
            new { OwnerId = ownerId, ConfirmName = confirmName, ByUserId = byUserId },
            commandType: CommandType.StoredProcedure,
            commandTimeout: 300,
            // Beech me request kat jaaye to bhi SP ka transaction poora ho ya poora wapas - token nahi.
            cancellationToken: CancellationToken.None));
        return rows.AsList();
    }
}
