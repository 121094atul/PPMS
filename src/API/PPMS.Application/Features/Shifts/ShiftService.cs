using PPMS.Application.Interfaces;

namespace PPMS.Application.Features.Shifts;

public sealed class ShiftService(IShiftRepository repository, IWhatsAppNotificationService whatsappService) : IShiftService
{
    public Task<long> OpenAsync(OpenShiftRequest request, CancellationToken cancellationToken = default)
    {
        return repository.OpenAsync(request, cancellationToken);
    }

    public async Task<long> CloseAsync(CloseShiftRequest request, long ownerId, CancellationToken cancellationToken = default)
    {
        var shiftId = await repository.CloseAsync(request, cancellationToken);
        if (shiftId > 0)
        {
            try
            {
                var summary = await repository.GetCollectionSummaryAsync(shiftId, cancellationToken);
                if (summary != null)
                {
                    var msg = $"🔔 *Shift Closed*\n\n" +
                              $"Shift ID: {request.Id}\n" +
                              $"Closing Cash: {request.ClosingCash:C}\n" +
                              $"Total UPI Sales: {summary.TotalUpiSales:C}\n" +
                              $"Total Card Sales: {summary.TotalCardSales:C}\n" +
                              $"Total Credit Sales: {summary.TotalCreditSales:C}\n" +
                              $"Total Expenses: {summary.TotalCashExpenses:C}\n" +
                              $"Bank Deposits: {summary.TotalBankDeposits:C}\n" +
                              (string.IsNullOrWhiteSpace(request.Notes) ? "" : $"Notes: {request.Notes}");

                    _ = Task.Run(() => whatsappService.SendToOwnerAsync(ownerId, "SHIFT_CLOSE", msg, CancellationToken.None));
                }
            }
            catch { /* Ignore alert failure */ }
        }
        return shiftId;
    }

    public Task<ShiftCollectionDto> GetCollectionAsync(long shiftId, long ownerId, CancellationToken cancellationToken = default)
        => repository.GetCollectionAsync(shiftId, ownerId, cancellationToken);

    public Task SaveCollectionAsync(SaveShiftCollectionRequest request, long ownerId, long? userId, CancellationToken cancellationToken = default)
        => repository.SaveCollectionAsync(request, ownerId, userId, cancellationToken);

    public Task<IReadOnlyList<MeterChainGapDto>> GetMeterChainGapsAsync(long ownerId, long? pumpId, int days, CancellationToken cancellationToken = default)
    {
        return repository.GetMeterChainGapsAsync(ownerId, pumpId, days, cancellationToken);
    }

    public Task<IReadOnlyList<ShiftNozzleReadingDto>> GetNozzleReadingsAsync(long shiftId, CancellationToken cancellationToken = default)
    {
        return repository.GetNozzleReadingsAsync(shiftId, cancellationToken);
    }

    public Task<IReadOnlyList<ShiftDto>> GetAllAsync(long ownerId, long? pumpId, CancellationToken cancellationToken = default)
    {
        return repository.GetAllAsync(ownerId, pumpId, cancellationToken);
    }

    public Task<PPMS.Shared.Models.PagedResponse<ShiftDto>> GetPagedListAsync(long ownerId, long? pumpId, DateTime? fromDate, DateTime? toDate, string? searchTerm, int pageNumber, int pageSize, CancellationToken cancellationToken = default)
    {
        return repository.GetPagedListAsync(ownerId, pumpId, fromDate, toDate, searchTerm, pageNumber, pageSize, cancellationToken);
    }

    public Task<ShiftCollectionSummaryDto> GetCollectionSummaryAsync(long shiftId, CancellationToken cancellationToken = default)
    {
        return repository.GetCollectionSummaryAsync(shiftId, cancellationToken);
    }

    public Task<IReadOnlyList<ShiftNozzleReadingDto>> GetLastNozzleReadingsAsync(long pumpId, DateOnly? beforeDate = null, CancellationToken cancellationToken = default)
    {
        return repository.GetLastNozzleReadingsAsync(pumpId, beforeDate, cancellationToken);
    }

    public Task<decimal> SaveCashDenominationAsync(long shiftId, SaveShiftCashDenominationRequest request, CancellationToken cancellationToken = default)
    {
        return repository.SaveCashDenominationAsync(shiftId, request, cancellationToken);
    }

    public Task<IReadOnlyList<SupportShiftDto>> GetSupportShiftsAsync(long ownerId, long? pumpId, int days, CancellationToken cancellationToken = default)
        => repository.GetSupportShiftsAsync(ownerId, pumpId, days, cancellationToken);

    public Task<bool> ReopenShiftAsync(long shiftId, long ownerId, long? userId, CancellationToken cancellationToken = default)
        => repository.ReopenShiftAsync(shiftId, ownerId, userId, cancellationToken);

    public Task<bool> DeleteShiftAsync(long shiftId, long ownerId, long? userId, string? reason, CancellationToken cancellationToken = default)
        => repository.DeleteShiftAsync(shiftId, ownerId, userId, reason, cancellationToken);

    public Task<IReadOnlyList<ShiftClosingDipRow>> GetClosingDipsAsync(long shiftId, long ownerId, CancellationToken cancellationToken = default)
        => repository.GetClosingDipsAsync(shiftId, ownerId, cancellationToken);

    public Task<IReadOnlyList<ShiftClosingDipSaved>> SaveClosingDipsAsync(long shiftId, long ownerId, long? userId, IReadOnlyList<ShiftClosingDipInput> dips, CancellationToken cancellationToken = default)
        => repository.SaveClosingDipsAsync(shiftId, ownerId, userId, dips, cancellationToken);
}
