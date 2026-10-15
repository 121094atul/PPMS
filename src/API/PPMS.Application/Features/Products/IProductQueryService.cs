namespace PPMS.Application.Features.Products;

public interface IProductQueryService
{
    Task<IReadOnlyList<ProductDto>> GetAllAsync(long ownerId, long? pumpId, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<ProductRateHistoryDto>> GetRateHistoryAsync(long productId, CancellationToken cancellationToken = default);
}
