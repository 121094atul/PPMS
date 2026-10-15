using Dapper;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;
using PPMS.Application.Features.Tanks;
using PPMS.Shared.Models;

namespace PPMS.Infrastructure.Persistence;

public sealed class TankReadRepository(IOptions<DatabaseOptions> options) : ITankReadRepository
{
    private readonly DatabaseOptions _options = options.Value;

    public async Task<PagedResponse<TankDto>> GetPagedListAsync(long ownerId, long pumpId, string? searchTerm, int pageNumber, int pageSize, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);

        using var multi = await connection.QueryMultipleAsync(
            sql: "PUMP.sp_Tank_List",
            param: new
            {
                OwnerId = ownerId > 0 ? ownerId : _options.DefaultOwnerId,
                PumpId = pumpId,
                SearchTerm = searchTerm,
                PageNumber = pageNumber,
                PageSize = pageSize
            },
            commandType: System.Data.CommandType.StoredProcedure);

        var items = await multi.ReadAsync<TankDto>();
        var totalCount = await multi.ReadSingleAsync<int>();

        return new PagedResponse<TankDto>(items.ToList(), totalCount, pageNumber, pageSize);
    }

    public async Task<decimal> GetStockAsOfDateAsync(long tankId, long ownerId, DateOnly date, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        var result = await connection.ExecuteScalarAsync<decimal?>(
            sql: "PUMP.sp_Tank_GetStockAsOfDate",
            param: new
            {
                OwnerId = ownerId,
                TankId = tankId,
                AsOfDate = date.ToDateTime(TimeOnly.MinValue)
            },
            commandType: System.Data.CommandType.StoredProcedure);

        return result ?? 0m;
    }

    public async Task<decimal> GetDipBookStockAsync(long tankId, long ownerId, DateOnly date, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        var result = await connection.ExecuteScalarAsync<decimal?>(
            sql: "PUMP.sp_Tank_GetDipBookStock",
            param: new { OwnerId = ownerId, TankId = tankId, AsOfDate = date.ToDateTime(TimeOnly.MinValue) },
            commandType: System.Data.CommandType.StoredProcedure);

        return result ?? 0m;
    }
}
