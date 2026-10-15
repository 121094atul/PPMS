namespace PPMS.Application.Features.Products;

public interface IProductCommandService
{
    Task SaveAsync(SaveProductRequest request, CancellationToken cancellationToken = default);
    Task DeleteAsync(long id, long ownerId, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<DailyRateDto>> GetDailyRatesAsync(long ownerId, long? pumpId, CancellationToken cancellationToken = default);
    Task<int> UpdateDailyRatesAsync(UpdateDailyRatesRequest request, long? userId, CancellationToken cancellationToken = default);
}
