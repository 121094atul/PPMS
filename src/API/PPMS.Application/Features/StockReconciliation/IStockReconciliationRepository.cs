namespace PPMS.Application.Features.StockReconciliation;

public interface IStockReconciliationRepository
{
    Task<long> SaveAsync(SaveStockReconciliationRequest request, CancellationToken cancellationToken = default);
    Task<PPMS.Shared.Models.PagedResponse<StockReconciliationDto>> GetPagedListAsync(long ownerId, long pumpId, long? tankId, DateTime? fromDate, DateTime? toDate, string? searchTerm, int pageNumber, int pageSize, CancellationToken cancellationToken = default);
}
