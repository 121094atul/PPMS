using Dapper;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;
using PPMS.Application.Features.CashTransactions;

namespace PPMS.Infrastructure.Persistence;

public sealed class CashTransactionRepository(IOptions<DatabaseOptions> options) : ICashTransactionRepository
{
    private readonly DatabaseOptions _options = options.Value;

    public async Task<long> SaveAsync(SaveCashTransactionRequest request, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        return await connection.ExecuteScalarAsync<long>(
            sql: "PUMP.sp_CashTxn_Save",
            param: new
            {
                request.OwnerId,
                request.PumpId,
                request.ShiftId,
                request.TxnType,
                request.Amount,
                request.ReferenceNo,
                request.Narration,
                request.TxnDateTime
            },
            commandType: System.Data.CommandType.StoredProcedure);
    }

    public async Task<PPMS.Shared.Models.PagedResponse<CashTransactionDto>> GetPagedListAsync(long ownerId, long pumpId, DateTime? fromDate, DateTime? toDate, string? searchTerm, int pageNumber, int pageSize, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        var multi = await connection.QueryMultipleAsync(
            sql: "PUMP.sp_CashTxn_List",
            param: new { OwnerId = ownerId, PumpId = pumpId, FromDate = fromDate, ToDate = toDate, SearchTerm = searchTerm, PageNumber = pageNumber, PageSize = pageSize },
            commandType: System.Data.CommandType.StoredProcedure);

        var items = (await multi.ReadAsync<CashTransactionDto>()).ToList();
        var totalCount = await multi.ReadSingleAsync<int>();

        return new PPMS.Shared.Models.PagedResponse<CashTransactionDto>(items, totalCount, pageNumber, pageSize);
    }

    public async Task DeleteAsync(long id, long ownerId, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        await connection.ExecuteAsync(
            sql: "PUMP.sp_CashTxn_Delete",
            param: new { Id = id, OwnerId = ownerId },
            commandType: System.Data.CommandType.StoredProcedure);
    }
}
