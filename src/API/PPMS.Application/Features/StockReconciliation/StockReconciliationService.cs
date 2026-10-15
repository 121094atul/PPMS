using PPMS.Application.Interfaces;

namespace PPMS.Application.Features.StockReconciliation;

public sealed class StockReconciliationService(IStockReconciliationRepository repository, IWhatsAppNotificationService whatsappService) : IStockReconciliationService
{
    public async Task<long> SaveAsync(SaveStockReconciliationRequest request, CancellationToken cancellationToken = default)
    {
        var id = await repository.SaveAsync(request, cancellationToken);
        if (id > 0)
        {
            var variance = request.PhysicalStock - request.BookStock;
            if (variance < -50) // More than 50L loss
            {
                var msg = $"⚠️ *High Stock Loss Detected*\n\n" +
                          $"Tank ID: {request.TankId}\n" +
                          $"Book Stock: {request.BookStock} Ltr\n" +
                          $"Physical Dip: {request.PhysicalStock} Ltr\n" +
                          $"Loss: {Math.Abs(variance):F2} Ltr\n" +
                          $"Reason: {request.Reason}";
                _ = Task.Run(() => whatsappService.SendToOwnerAsync(request.OwnerId, "STOCK_LOSS", msg, CancellationToken.None));
            }
        }
        return id;
    }

    public Task<PPMS.Shared.Models.PagedResponse<StockReconciliationDto>> GetPagedListAsync(long ownerId, long pumpId, long? tankId, DateTime? fromDate, DateTime? toDate, string? searchTerm, int pageNumber, int pageSize, CancellationToken cancellationToken = default)
        => repository.GetPagedListAsync(ownerId, pumpId, tankId, fromDate, toDate, searchTerm, pageNumber, pageSize, cancellationToken);
}
