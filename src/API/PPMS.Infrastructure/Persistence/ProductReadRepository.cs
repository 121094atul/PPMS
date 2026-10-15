using Dapper;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;
using PPMS.Application.Features.Products;

namespace PPMS.Infrastructure.Persistence;

public sealed class ProductReadRepository(IOptions<DatabaseOptions> options) : IProductReadRepository
{
    private readonly DatabaseOptions _options = options.Value;

    public async Task<IReadOnlyList<ProductDto>> GetAllAsync(long ownerId, long? pumpId, CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(_options.ConnectionString))
        {
            return Array.Empty<ProductDto>();
        }

        await using var connection = new SqlConnection(_options.ConnectionString);

        var rows = await connection.QueryAsync<ProductDto>(
            sql: "PUMP.sp_Product_List",
            param: new
            {
                OwnerId = ownerId > 0 ? ownerId : _options.DefaultOwnerId,
                PumpId = pumpId
            },
            commandType: System.Data.CommandType.StoredProcedure);

        return rows.AsList();
    }

    public async Task<IReadOnlyList<ProductRateHistoryDto>> GetRateHistoryAsync(long productId, CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(_options.ConnectionString)) return Array.Empty<ProductRateHistoryDto>();

        await using var connection = new SqlConnection(_options.ConnectionString);
        var rows = await connection.QueryAsync<ProductRateHistoryDto>(
            sql: "PUMP.sp_ProductRateHistory_List",
            param: new { ProductId = productId },
            commandType: System.Data.CommandType.StoredProcedure);

        return rows.AsList();
    }
}
