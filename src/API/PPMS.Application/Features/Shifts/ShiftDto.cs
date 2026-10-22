namespace PPMS.Application.Features.Shifts;

public sealed record ShiftDto(
    long Id,
    long OwnerId,
    long PumpId,
    long? OperatorUserId,
    // Shift ka in-charge ab Employees se aata hai (Section K). OperatorUserId
    // saath me bharta rehta hai taaki purani reports na tootein.
    long? OperatorEmployeeId,
    string? OperatorName,
    DateOnly ShiftDate,
    string ShiftCode,
    decimal OpeningCash,
    decimal? ClosingCash,
    decimal TotalSoldQty,
    decimal TotalSoldAmount,
    string? Notes,
    DateTime OpenedOn,
    DateTime? ClosedOn,
    string Status,
    // Us pump par us din ki kaunsi shift — 1, 2, 3 (Section X). Screen par yahi
    // dikhta hai; Id andar ka number hai, jo kuch mahine me 4-5 ank ka ho jaata
    // hai aur pump wale ke liye uska koi matlab nahi.
    int ShiftNo,
    // Section AN: band karte waqt nikla asli short / excess (ShiftHeaders.CashShortExcess), aur shift band par
    // apne aap "malik ko diya" gaya nakad. Galle me ab 0 bachta hai, isliye list ye do khud nahi nikaal sakti.
    // Purane SP se null.
    decimal? CashShortExcess = null,
    decimal? CashToOwner = null
);
