using PPMS.Application.Interfaces;
using System.Linq;

namespace PPMS.Application.Features.Purchases;

public sealed class PurchaseService(IPurchaseRepository repository, IWhatsAppNotificationService whatsappService) : IPurchaseService
{
    public async Task<long> SaveAsync(SavePurchaseRequest request, CancellationToken cancellationToken = default)
    {
        PPMS.Application.Common.EntryGuard.NotInFuture(request.InvoiceDate, "Invoice date");

        if (request.Items is null || request.Items.Count == 0)
        {
            throw new InvalidOperationException("At least one purchase item is required.");
        }

        foreach (var item in request.Items)
        {
            PPMS.Application.Common.EntryGuard.PositiveQuantity(item.Quantity, "Purchase quantity");
            // Bill ki rakam di ho to rate ki zaroorat nahi (Section AE). Purana
            // client sirf rate bhejta hai - tab wahi purani jaanch.
            if (item.Amount is not > 0)
            {
                PPMS.Application.Common.EntryGuard.PositiveRate(item.Rate, "Purchase rate");
            }
        }

        var id = await repository.SaveAsync(request, cancellationToken);
        if (id > 0)
        {
            var totalQty = request.Items.Sum(i => i.Quantity);
            var totalAmount = request.Items.Sum(i => i.LineAmount);
            
            var msg = $"🚚 *Stock Purchase Alert*\n\n" +
                      $"Invoice: {request.InvoiceNo}\n" +
                      $"Vehicle: {request.VehicleNo}\n" +
                      $"Total Qty: {totalQty:F2} Ltr\n" +
                      $"Total Amount: {totalAmount:C}";
            _ = Task.Run(() => whatsappService.SendToOwnerAsync(request.OwnerId, "PURCHASE", msg, CancellationToken.None));
        }
        return id;
    }

    public Task<PPMS.Shared.Models.PagedResponse<PurchaseDto>> GetPagedListAsync(long ownerId, long pumpId, DateTime? fromDate, DateTime? toDate, string? searchTerm, int pageNumber, int pageSize, CancellationToken cancellationToken = default)
        => repository.GetPagedListAsync(ownerId, pumpId, fromDate, toDate, searchTerm, pageNumber, pageSize, cancellationToken);

    public Task DeleteAsync(long id, long ownerId, CancellationToken cancellationToken = default)
        => repository.DeleteAsync(id, ownerId, cancellationToken);

    public Task<PurchaseDetailDto?> GetByIdAsync(long id, long ownerId, CancellationToken cancellationToken = default)
        => repository.GetByIdAsync(id, ownerId, cancellationToken);
}
