using Dapper;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;
using PPMS.Application.Features.Expenses;

namespace PPMS.Infrastructure.Persistence;

public sealed class ExpenseRepository(IOptions<DatabaseOptions> options) : IExpenseRepository
{
    private readonly DatabaseOptions _options = options.Value;

    public async Task<long> SaveAsync(SaveExpenseRequest request, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        return await connection.ExecuteScalarAsync<long>(
            sql: "PUMP.sp_Expense_Save",
            param: new
            {
                request.OwnerId,
                request.PumpId,
                request.ShiftId,
                request.ExpenseHeadId,
                request.Amount,
                request.PaymentMode,
                request.ReferenceNo,
                request.Narration,
                request.TxnDateTime
            },
            commandType: System.Data.CommandType.StoredProcedure);
    }

    public async Task<IReadOnlyList<ExpenseDto>> GetByPumpAsync(long ownerId, long pumpId, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        var rows = await connection.QueryAsync<ExpenseDto>(
            sql: "PUMP.sp_Expense_List",
            param: new { OwnerId = ownerId, PumpId = pumpId },
            commandType: System.Data.CommandType.StoredProcedure);

        return rows.AsList();
    }

    public async Task<PPMS.Shared.Models.PagedResponse<ExpenseDto>> GetPagedByPumpAsync(long ownerId, long pumpId, DateTime? fromDate, DateTime? toDate, string? searchTerm, int pageNumber, int pageSize, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);

        using var multi = await connection.QueryMultipleAsync(
            sql: "PUMP.sp_Expense_List",
            param: new
            {
                OwnerId = ownerId,
                PumpId = pumpId,
                FromDate = fromDate,
                ToDate = toDate,
                SearchTerm = searchTerm,
                PageNumber = pageNumber,
                PageSize = pageSize
            },
            commandType: System.Data.CommandType.StoredProcedure);

        var items = await multi.ReadAsync<ExpenseDto>();
        var totalCount = await multi.ReadSingleAsync<int>();

        return new PPMS.Shared.Models.PagedResponse<ExpenseDto>(items.ToList(), totalCount, pageNumber, pageSize);
    }

    public async Task DeleteAsync(long id, long ownerId, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        await connection.ExecuteAsync(
            sql: "PUMP.sp_Expense_Delete",
            param: new { Id = id, OwnerId = ownerId },
            commandType: System.Data.CommandType.StoredProcedure);
    }
}
