namespace PPMS.Application.Features.Products;

public sealed class ProductCommandService(IProductCommandRepository repository) : IProductCommandService
{
    public Task SaveAsync(SaveProductRequest request, CancellationToken cancellationToken = default)
    {
        return repository.SaveAsync(request, cancellationToken);
    }

    public Task DeleteAsync(long id, long ownerId, CancellationToken cancellationToken = default)
    {
        return repository.DeleteAsync(id, ownerId, cancellationToken);
    }

    public Task<IReadOnlyList<DailyRateDto>> GetDailyRatesAsync(long ownerId, long? pumpId, CancellationToken cancellationToken = default)
    {
        return repository.GetDailyRatesAsync(ownerId, pumpId, cancellationToken);
    }

    public Task<int> UpdateDailyRatesAsync(UpdateDailyRatesRequest request, long? userId, CancellationToken cancellationToken = default)
    {
        if (request.Rates is null || request.Rates.Count == 0)
        {
            throw new InvalidOperationException("At least one rate is required.");
        }

        // Rate 0 ya minus kabhi valid nahi. UI par min="0.01" hai lekin API seedha
        // bhi hit ho sakti hai, aur galat rate poore mahine ki sale bigaad dega.
        foreach (var line in request.Rates)
        {
            PPMS.Application.Common.EntryGuard.PositiveRate(line.NewRate, "Rate");
        }

        // Ek hi product do baar aa jaye to kaunsa rate lagega — pata nahi. Saaf
        // mana kar dena behtar hai.
        if (request.Rates.Select(x => x.ProductId).Distinct().Count() != request.Rates.Count)
        {
            throw new InvalidOperationException("Same product appears more than once.");
        }

        return repository.UpdateDailyRatesAsync(request, userId, cancellationToken);
    }
}
