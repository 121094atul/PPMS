using PPMS.Shared.Models;

namespace PPMS.Application.Features.Tanks;

public interface ITankReadRepository
{
    Task<PagedResponse<TankDto>> GetPagedListAsync(long ownerId, long pumpId, string? searchTerm, int pageNumber, int pageSize, CancellationToken cancellationToken = default);
    Task<decimal> GetStockAsOfDateAsync(long tankId, long ownerId, DateOnly date, CancellationToken cancellationToken = default);

    /// <summary>Dip ke liye book stock — DSR wala hisaab (Section AB). Stock Reconcile
    /// ke liye upar wala hi rehna chahiye.</summary>
    Task<decimal> GetDipBookStockAsync(long tankId, long ownerId, DateOnly date, CancellationToken cancellationToken = default);
}
