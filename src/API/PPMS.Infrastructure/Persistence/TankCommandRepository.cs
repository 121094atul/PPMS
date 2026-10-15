using Dapper;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;
using PPMS.Application.Features.Tanks;

namespace PPMS.Infrastructure.Persistence;

public sealed class TankCommandRepository(IOptions<DatabaseOptions> options) : ITankCommandRepository
{
    private readonly DatabaseOptions _options = options.Value;

    public async Task SaveAsync(SaveTankRequest request, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        await connection.ExecuteAsync(
            sql: "PUMP.sp_Tank_Save",
            param: new
            {
                request.Id,
                OwnerId = request.OwnerId > 0 ? request.OwnerId : _options.DefaultOwnerId,
                request.PumpId,
                request.Name,
                request.ProductId,
                request.Capacity,
                request.SafeFillLevel,
                request.CurrentStock,
                request.IsActive
            },
            commandType: System.Data.CommandType.StoredProcedure);
    }

    public async Task DeleteAsync(long id, long ownerId, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        await connection.ExecuteAsync(
            sql: "PUMP.sp_Tank_Delete",
            param: new { Id = id, OwnerId = ownerId },
            commandType: System.Data.CommandType.StoredProcedure);
    }
}
