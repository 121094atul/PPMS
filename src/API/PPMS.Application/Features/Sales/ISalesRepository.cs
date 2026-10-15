namespace PPMS.Application.Features.Sales;

public interface ISalesRepository
{
    Task<long> SaveAsync(SaveSaleRequest request, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<SaleDto>> GetAllAsync(long ownerId, long? pumpId, CancellationToken cancellationToken = default);
    Task<PPMS.Shared.Models.PagedResponse<SaleDto>> GetPagedListAsync(long ownerId, long? pumpId, DateTime? fromDate, DateTime? toDate, string? searchTerm, int pageNumber, int pageSize, CancellationToken cancellationToken = default);
    Task<ReceiptDto?> GenerateReceiptAsync(long salesHeaderId, CancellationToken cancellationToken = default);
    Task VoidAsync(long id, long ownerId, long? userId, string? reason, CancellationToken cancellationToken = default);
}
