using PPMS.Shared.Models;

namespace PPMS.Application.Features.Tanks;

public sealed class TankQueryService(ITankReadRepository repository) : ITankQueryService
{
    public Task<PagedResponse<TankDto>> GetPagedListAsync(long ownerId, long pumpId, string? searchTerm, int pageNumber, int pageSize, CancellationToken cancellationToken = default)
    {
        return repository.GetPagedListAsync(ownerId, pumpId, searchTerm, pageNumber, pageSize, cancellationToken);
    }

    public Task<decimal> GetStockAsOfDateAsync(long tankId, long ownerId, DateOnly date, CancellationToken cancellationToken = default)
    {
        return repository.GetStockAsOfDateAsync(tankId, ownerId, date, cancellationToken);
    }

    public Task<decimal> GetDipBookStockAsync(long tankId, long ownerId, DateOnly date, CancellationToken cancellationToken = default)
    {
        return repository.GetDipBookStockAsync(tankId, ownerId, date, cancellationToken);
    }
}
