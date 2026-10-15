namespace PPMS.Application.Features.Products;

public sealed class ProductQueryService(IProductReadRepository repository) : IProductQueryService
{
    public Task<IReadOnlyList<ProductDto>> GetAllAsync(long ownerId, long? pumpId, CancellationToken cancellationToken = default)
    {
        return repository.GetAllAsync(ownerId, pumpId, cancellationToken);
    }

    public Task<IReadOnlyList<ProductRateHistoryDto>> GetRateHistoryAsync(long productId, CancellationToken cancellationToken = default)
    {
        return repository.GetRateHistoryAsync(productId, cancellationToken);
    }
}
