using Dapper;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;
using PPMS.Application.Features.Nozzles;

namespace PPMS.Infrastructure.Persistence;

public sealed class NozzleRepository(IOptions<DatabaseOptions> options) : INozzleRepository
{
    private readonly DatabaseOptions _options = options.Value;

    public async Task<IReadOnlyList<NozzleDto>> GetByPumpAsync(long ownerId, long? pumpId, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        var rows = await connection.QueryAsync<NozzleDto>(
            sql: "PUMP.sp_Nozzle_List",
            param: new
            {
                OwnerId = ownerId,
                PumpId = pumpId
            },
            commandType: System.Data.CommandType.StoredProcedure);

        return rows.AsList();
    }

    public async Task<long> SaveAsync(SaveNozzleRequest request, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        return await connection.ExecuteScalarAsync<long>(
            sql: "PUMP.sp_Nozzle_Save",
            param: new
            {
                request.Id,
                request.OwnerId,
                request.PumpId,
                request.ProductId,
                request.NozzleCode,
                request.TankId
            },
            commandType: System.Data.CommandType.StoredProcedure);
    }

    public async Task DeleteAsync(long id, long ownerId, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        await connection.ExecuteAsync(
            sql: "PUMP.sp_Nozzle_Delete",
            param: new { Id = id, OwnerId = ownerId },
            commandType: System.Data.CommandType.StoredProcedure);
    }
}
