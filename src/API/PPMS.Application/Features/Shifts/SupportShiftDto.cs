namespace PPMS.Application.Features.Shifts;

/// <summary>
/// Support console ki ek line — kisi bhi owner ki ek shift, aur us se kya-kya
/// juda hua hai (Section Z).
///
/// Ye sirf Super Admin ke liye hai. Ab tak galti se band hui shift kholna ya
/// khaali shift hatana SIRF SQL se ho paata tha; har baar developer ko database
/// me ghusna padta tha. Ginti ke ye khaane isliye hain ki faisla DEKH kar ho —
/// andaaze se nahi.
///
/// NOTE (CLAUDE.md niyam 5): param theek `sp_Support_ShiftList` ke column ke
/// kram, naam aur type se milte hain. SP me column badlo to yahan bhi badalna
/// hoga, warna Dapper row bana hi nahi paayega aur endpoint 500 dega.
/// </summary>
public sealed record SupportShiftDto(
    long Id,
    long PumpId,
    string? PumpName,
    DateOnly ShiftDate,
    string ShiftCode,
    string Status,
    DateTime OpenedOn,
    DateTime? ClosedOn,
    decimal TotalMeterSale,
    decimal OpeningCash,
    decimal? ClosingCash,
    int NozzleCount,
    int ReadingsFilled,
    int SalesCount,
    int CashTxnCount,
    int ExpenseCount,
    int DipCount,
    int TankTxnCount,
    // Stock hil chuka ho to shift yun hi kholna tank ka hisaab bigaad dega.
    bool CanReopen,
    // Hatane layak sirf wahi shift jisme sach me kuch hai hi nahi.
    bool CanDelete
);
