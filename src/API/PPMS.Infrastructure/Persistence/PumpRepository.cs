using Dapper;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;
using PPMS.Application.Features.Pumps;

namespace PPMS.Infrastructure.Persistence;

public sealed class PumpRepository(IOptions<DatabaseOptions> options) : IPumpRepository
{
    private readonly DatabaseOptions _options = options.Value;

    public async Task<IReadOnlyList<PumpDto>> GetByOwnerIdAsync(long ownerId, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        var rows = await connection.QueryAsync<PumpDto>(
            sql: "PUMP.sp_Pump_List",
            param: new { OwnerId = ownerId },
            commandType: System.Data.CommandType.StoredProcedure);

        return rows.AsList();
    }

    public async Task<long> SaveAsync(SavePumpRequest request, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        return await connection.ExecuteScalarAsync<long>(
            sql: "PUMP.sp_Pump_Save",
            param: new
            {
                request.Id,
                request.OwnerId,
                request.Name,
                request.City,
                request.Address,
                request.ContactNo,
                request.GSTIN
            },
            commandType: System.Data.CommandType.StoredProcedure);
    }

    public async Task DeleteAsync(long id, long ownerId, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        await connection.ExecuteAsync(
            sql: "PUMP.sp_Pump_Delete",
            param: new { Id = id, OwnerId = ownerId },
            commandType: System.Data.CommandType.StoredProcedure);
    }
}
