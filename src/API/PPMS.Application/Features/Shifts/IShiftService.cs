namespace PPMS.Application.Features.Shifts;

public interface IShiftService
{
    Task<long> OpenAsync(OpenShiftRequest request, CancellationToken cancellationToken = default);
    /// <param name="ownerId">
    /// JWT se aaya hua owner. Endpoint par ITenantGuard pehle hi jaanch chuka hota hai
    /// ki ye shift isi owner ki hai. Yahan iska kaam alert sahi malik tak bhejna hai.
    /// </param>
    Task<long> CloseAsync(CloseShiftRequest request, long ownerId, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<ShiftNozzleReadingDto>> GetNozzleReadingsAsync(long shiftId, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<ShiftDto>> GetAllAsync(long ownerId, long? pumpId, CancellationToken cancellationToken = default);
    Task<PPMS.Shared.Models.PagedResponse<ShiftDto>> GetPagedListAsync(long ownerId, long? pumpId, DateTime? fromDate, DateTime? toDate, string? searchTerm, int pageNumber, int pageSize, CancellationToken cancellationToken = default);
    Task<ShiftCollectionSummaryDto> GetCollectionSummaryAsync(long shiftId, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<ShiftNozzleReadingDto>> GetLastNozzleReadingsAsync(long pumpId, DateOnly? beforeDate = null, CancellationToken cancellationToken = default);
    /// <summary>
    /// Meter ki tooti hui kadi (Section R2). Sirf batata hai, rokta kuch nahi.
    /// </summary>
    Task<IReadOnlyList<MeterChainGapDto>> GetMeterChainGapsAsync(long ownerId, long? pumpId, int days, CancellationToken cancellationToken = default);
    /// <summary>Din ka collection — Online / Card / udhaar (Section W).</summary>
    Task<ShiftCollectionDto> GetCollectionAsync(long shiftId, long ownerId, CancellationToken cancellationToken = default);
    Task SaveCollectionAsync(SaveShiftCollectionRequest request, long ownerId, long? userId, CancellationToken cancellationToken = default);
    /// <summary>Wahi party, wahi din, wahi rakam ki udhaar pehle se (Section AQ4).</summary>
    Task<IReadOnlyList<CreditDuplicateDto>> FindCreditDuplicatesAsync(CreditDuplicateCheckRequest request, long ownerId, CancellationToken cancellationToken = default);
    Task<decimal> SaveCashDenominationAsync(long shiftId, SaveShiftCashDenominationRequest request, CancellationToken cancellationToken = default);

    // Support console (Section Z) — Super Admin hi call karta hai.
    Task<IReadOnlyList<SupportShiftDto>> GetSupportShiftsAsync(long ownerId, long? pumpId, int days, CancellationToken cancellationToken = default);
    Task<bool> ReopenShiftAsync(long shiftId, long ownerId, long? userId, CancellationToken cancellationToken = default);
    Task<bool> DeleteShiftAsync(long shiftId, long ownerId, long? userId, string? reason, CancellationToken cancellationToken = default);

    // Close Shift form me dip (Section AB).
    Task<IReadOnlyList<ShiftClosingDipRow>> GetClosingDipsAsync(long shiftId, long ownerId, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<ShiftClosingDipSaved>> SaveClosingDipsAsync(long shiftId, long ownerId, long? userId, IReadOnlyList<ShiftClosingDipInput> dips, CancellationToken cancellationToken = default);
}
