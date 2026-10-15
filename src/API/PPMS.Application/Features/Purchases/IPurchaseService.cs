namespace PPMS.Application.Features.Purchases;

public interface IPurchaseService
{
    Task<long> SaveAsync(SavePurchaseRequest request, CancellationToken cancellationToken = default);
    Task<PPMS.Shared.Models.PagedResponse<PurchaseDto>> GetPagedListAsync(long ownerId, long pumpId, DateTime? fromDate, DateTime? toDate, string? searchTerm, int pageNumber, int pageSize, CancellationToken cancellationToken = default);
    Task DeleteAsync(long id, long ownerId, CancellationToken cancellationToken = default);
    Task<PurchaseDetailDto?> GetByIdAsync(long id, long ownerId, CancellationToken cancellationToken = default);
}
