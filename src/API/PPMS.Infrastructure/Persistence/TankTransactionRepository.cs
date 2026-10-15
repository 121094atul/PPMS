using Dapper;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;
using PPMS.Application.Features.TankTransactions;

namespace PPMS.Infrastructure.Persistence;

public sealed class TankTransactionRepository(IOptions<DatabaseOptions> options) : ITankTransactionRepository
{
    private readonly DatabaseOptions _options = options.Value;

    public async Task<long> SaveAsync(SaveTankTransactionRequest request, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        return await connection.ExecuteScalarAsync<long>(
            sql: "PUMP.sp_TankTxn_Save",
            param: new
            {
                request.OwnerId,
                request.PumpId,
                request.TankId,
                request.TxnType,
                request.Quantity,
                request.ReferenceNo,
                request.Notes,
                request.TxnDateTime
            },
            commandType: System.Data.CommandType.StoredProcedure);
    }

    public async Task<IReadOnlyList<TankTransactionDto>> GetByPumpAsync(long ownerId, long pumpId, long? tankId, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        var rows = await connection.QueryAsync<TankTransactionDto>(
            sql: "PUMP.sp_TankTxn_List",
            param: new
            {
                OwnerId = ownerId,
                PumpId = pumpId,
                TankId = tankId
            },
            commandType: System.Data.CommandType.StoredProcedure);

        return rows.AsList();
    }
}
