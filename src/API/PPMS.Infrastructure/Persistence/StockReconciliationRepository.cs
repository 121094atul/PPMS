using Dapper;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;
using PPMS.Application.Features.StockReconciliation;

namespace PPMS.Infrastructure.Persistence;

public sealed class StockReconciliationRepository(IOptions<DatabaseOptions> options) : IStockReconciliationRepository
{
    private readonly DatabaseOptions _options = options.Value;

    public async Task<long> SaveAsync(SaveStockReconciliationRequest request, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        return await connection.ExecuteScalarAsync<long>(
            sql: "PUMP.sp_StockReconcile_Save",
            param: new
            {
                request.OwnerId,
                request.PumpId,
                request.TankId,
                ReconciliationDate = request.ReconciliationDate.ToDateTime(TimeOnly.MinValue),
                request.BookStock,
                request.PhysicalStock,
                request.Reason
            },
            commandType: System.Data.CommandType.StoredProcedure);
    }

    public async Task<PPMS.Shared.Models.PagedResponse<StockReconciliationDto>> GetPagedListAsync(long ownerId, long pumpId, long? tankId, DateTime? fromDate, DateTime? toDate, string? searchTerm, int pageNumber, int pageSize, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        using var multi = await connection.QueryMultipleAsync(
            sql: "PUMP.sp_StockReconcile_List",
            param: new
            {
                OwnerId = ownerId,
                PumpId = pumpId,
                TankId = tankId,
                FromDate = fromDate,
                ToDate = toDate,
                PageNumber = pageNumber,
                PageSize = pageSize
            },
            commandType: System.Data.CommandType.StoredProcedure);

        var items = await multi.ReadAsync<StockReconciliationDto>();
        var totalCount = await multi.ReadSingleAsync<int>();

        return new PPMS.Shared.Models.PagedResponse<StockReconciliationDto>(items.ToList(), totalCount, pageNumber, pageSize);
    }
}
