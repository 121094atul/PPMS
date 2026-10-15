using Dapper;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;
using PPMS.Application.Features.Products;

namespace PPMS.Infrastructure.Persistence;

public sealed class ProductCommandRepository(IOptions<DatabaseOptions> options) : IProductCommandRepository
{
    private readonly DatabaseOptions _options = options.Value;

    public async Task SaveAsync(SaveProductRequest request, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        await connection.ExecuteAsync(
            sql: "PUMP.sp_Product_Save",
            param: new
            {
                request.Id,
                request.OwnerId,
                request.PumpId,
                request.Name,
                request.Category,
                request.Unit,
                request.CurrentRate,
                request.HSNCode,
                request.CGSTRate,
                request.SGSTRate
            },
            commandType: System.Data.CommandType.StoredProcedure);
    }

    public async Task DeleteAsync(long id, long ownerId, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        await connection.ExecuteAsync(
            sql: "PUMP.sp_Product_Delete",
            param: new { Id = id, OwnerId = ownerId },
            commandType: System.Data.CommandType.StoredProcedure);
    }

    public async Task<IReadOnlyList<DailyRateDto>> GetDailyRatesAsync(long ownerId, long? pumpId, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        var rows = await connection.QueryAsync<DailyRateDto>(
            sql: "PUMP.sp_Product_DailyRateList",
            param: new { OwnerId = ownerId, PumpId = pumpId },
            commandType: System.Data.CommandType.StoredProcedure);

        return rows.AsList();
    }

    public async Task<int> UpdateDailyRatesAsync(UpdateDailyRatesRequest request, long? userId, CancellationToken cancellationToken = default)
    {
        // SP @RatesJson leta hai — har grade ka apna rate. Category-wide update
        // jaanbujh ke istemaal nahi kar rahe: usse Normal/Premium/E20 sab ek hi
        // rate par chale jaate hain (G13 ke saath ye bug pakda gaya tha).
        var json = System.Text.Json.JsonSerializer.Serialize(
            request.Rates.Select(x => new { x.ProductId, x.NewRate }));

        await using var connection = new SqlConnection(_options.ConnectionString);
        return await connection.ExecuteScalarAsync<int>(
            sql: "PUMP.sp_Product_BulkRateUpdate",
            param: new
            {
                request.OwnerId,
                RatesJson = json,
                UserId = userId
            },
            commandType: System.Data.CommandType.StoredProcedure);
    }
}
