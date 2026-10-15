using Dapper;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;
using PPMS.Application.Features.ExpenseHeads;

namespace PPMS.Infrastructure.Persistence;

public sealed class ExpenseHeadRepository(IOptions<DatabaseOptions> options) : IExpenseHeadRepository
{
    private readonly DatabaseOptions _options = options.Value;

    public async Task<long> SaveAsync(SaveExpenseHeadRequest request, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        return await connection.ExecuteScalarAsync<long>(
            sql: "PUMP.sp_ExpenseHead_Save",
            param: new { request.Id, request.OwnerId, request.PumpId, request.HeadName, request.IsActive },
            commandType: System.Data.CommandType.StoredProcedure);
    }

    public async Task<IReadOnlyList<ExpenseHeadDto>> GetByPumpAsync(long ownerId, long pumpId, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        var rows = await connection.QueryAsync<ExpenseHeadDto>(
            sql: "PUMP.sp_ExpenseHead_List",
            param: new { OwnerId = ownerId, PumpId = pumpId },
            commandType: System.Data.CommandType.StoredProcedure);

        return rows.AsList();
    }

    public async Task DeleteAsync(long id, long ownerId, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        await connection.ExecuteAsync(
            sql: "PUMP.sp_ExpenseHead_Delete",
            param: new { Id = id, OwnerId = ownerId },
            commandType: System.Data.CommandType.StoredProcedure);
    }
}
