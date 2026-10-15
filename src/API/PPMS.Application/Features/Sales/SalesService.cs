using PPMS.Application.Common;

namespace PPMS.Application.Features.Sales;

public sealed class SalesService(ISalesRepository repository) : ISalesService
{
    public Task<long> SaveAsync(SaveSaleRequest request, CancellationToken cancellationToken = default)
    {
        // UI ke min="0.01" par bharosa nahi kiya ja sakta — API seedha bhi hit ho sakti hai.
        EntryGuard.NotInFuture(request.BillDateTime, "Bill date");

        if (request.Items is null || request.Items.Count == 0)
        {
            throw new InvalidOperationException("At least one sale item is required.");
        }

        foreach (var item in request.Items)
        {
            EntryGuard.PositiveQuantity(item.Quantity, "Sale quantity");
            EntryGuard.PositiveRate(item.Rate, "Sale rate");
        }

        return repository.SaveAsync(request, cancellationToken);
    }

    public Task<IReadOnlyList<SaleDto>> GetAllAsync(long ownerId, long? pumpId, CancellationToken cancellationToken = default)
    {
        return repository.GetAllAsync(ownerId, pumpId, cancellationToken);
    }

    public Task<PPMS.Shared.Models.PagedResponse<SaleDto>> GetPagedListAsync(long ownerId, long? pumpId, DateTime? fromDate, DateTime? toDate, string? searchTerm, int pageNumber, int pageSize, CancellationToken cancellationToken = default)
    {
        return repository.GetPagedListAsync(ownerId, pumpId, fromDate, toDate, searchTerm, pageNumber, pageSize, cancellationToken);
    }

    public Task<ReceiptDto?> GenerateReceiptAsync(long salesHeaderId, CancellationToken cancellationToken = default)
    {
        return repository.GenerateReceiptAsync(salesHeaderId, cancellationToken);
    }

    public Task VoidAsync(long id, long ownerId, long? userId, string? reason, CancellationToken cancellationToken = default)
        => repository.VoidAsync(id, ownerId, userId, reason, cancellationToken);
}
