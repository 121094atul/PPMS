using PPMS.Client.Web.Services;

namespace PPMS.Client.Web.Models;

/// <summary>
/// "Aaj ki shift" — poori shift ek hi screen par (Operations/TodayShift).
///
/// Pehle shift ka kaam paanch jagah bikhra tha: Open Shift form, Close Shift ka
/// modal, alag "Count Cash", Day Collection, aur Dip. In-charge ko kram yaad rakhna
/// padta tha, aur galti wahin hoti thi (collection bhoola, dip bhooli, cash bina
/// gine band). Ye screen wahi purane API chalati hai, bas ek kram me:
///
///   khuli shift nahi  → "shuru karein" (tareekh, in-charge; opening apne aap)
///   khuli shift hai   → 1 meter  2 tank dip  3 paisa  4 milaan aur band
///
/// Neeche hamesha teen number: bikri, kitna cash aana chahiye, aur farak.
/// </summary>
public sealed class TodayShiftViewModel
{
    public IReadOnlyList<ApiPumpDto> Pumps { get; set; } = Array.Empty<ApiPumpDto>();
    public long PumpId { get; set; }
    public string PumpName { get; set; } = string.Empty;

    public string? Message { get; set; }
    public bool IsError { get; set; }

    /// <summary>Khuli shift. Hai to "bharo aur band karo", nahi to "shuru karo".</summary>
    public ApiShiftDto? Shift { get; set; }
    public bool IsRunning => Shift is not null;

    /// <summary>Abhi-abhi band hui shift ka chhota hisaab — upar hara dabba.</summary>
    public TodayShiftClosedInfo? JustClosed { get; set; }

    public DateOnly Today { get; set; }

    // ── Shuru karna (koi shift khuli nahi) ────────────────────────────────
    public ApiShiftDto? LastShift { get; set; }
    public TodayShiftStartForm Start { get; set; } = new();
    public IReadOnlyList<ApiEmployeeDto> Employees { get; set; } = Array.Empty<ApiEmployeeDto>();

    /// <summary>Aakhri shift aur chuni hui tareekh ke beech chhoote din.</summary>
    public int GapDays { get; set; }
    public DateOnly? GapFrom { get; set; }

    /// <summary>Chuni hui tareekh ke BAAD ka din pehle se bhara hai — beech me din ghusana galat.</summary>
    public DateOnly? LaterDate { get; set; }

    /// <summary>Is din ki shift pehle se hai — ye doosri hogi (code B, C...).</summary>
    public string? SameDayCodes { get; set; }

    // ── Chalti shift ──────────────────────────────────────────────────────
    public IReadOnlyList<ApiShiftNozzleReadingDto> Nozzles { get; set; } = Array.Empty<ApiShiftNozzleReadingDto>();

    /// <summary>Nozzle → pichhli shift me kitni testing hui thi. Is pump par roz 5 L hoti hai, to pehle se bhar dete hain.</summary>
    public IReadOnlyDictionary<long, decimal> LastTesting { get; set; } = new Dictionary<long, decimal>();

    public IReadOnlyList<ApiShiftClosingDipRow> Tanks { get; set; } = Array.Empty<ApiShiftClosingDipRow>();

    /// <summary>Product ka naam → ikai ("Litre", "Kg"...). CNG kilo me hai: uski testing aur dip nahi hoti.</summary>
    public IReadOnlyDictionary<string, string> ProductUnits { get; set; } = new Dictionary<string, string>();
    public ApiShiftCollection Collection { get; set; } = new(0, 0, new List<ApiShiftCollectionCreditLine>());
    public IReadOnlyList<ApiPartyDto> Parties { get; set; } = Array.Empty<ApiPartyDto>();
    public IReadOnlyList<ApiExpenseHeadDto> ExpenseHeads { get; set; } = Array.Empty<ApiExpenseHeadDto>();
    public IReadOnlyList<ApiExpenseDto> Expenses { get; set; } = Array.Empty<ApiExpenseDto>();

    /// <summary>Is shift me galle se nikala nakad (malik ko diya / bank me jama).</summary>
    public IReadOnlyList<TodayShiftHandover> Handovers { get; set; } = Array.Empty<TodayShiftHandover>();

    /// <summary>Shuru karte waqt: pichhli shift ke closing wala nakad (galle me jitna bacha tha).</summary>
    public decimal SuggestedOpeningCash { get; set; }
    /// <summary>Shift band hone par galle me itna bachta hai, baaki apne aap malik ko (Section AN).</summary>
    public decimal KeepInDrawer { get; set; }
    public TodayShiftCashParts Cash { get; set; } = new();
    public decimal ToleranceRs { get; set; } = 100;
}

public sealed class TodayShiftStartForm
{
    public long PumpId { get; set; }

    /// <summary>
    /// Galle me shuru ka nakad. Aam taur par pichhli shift ke closing se aata hai (server wahi dobara nikaalta hai).
    /// Asli galla alag ho (jaise purana jama hua nakad) to user badal sakta hai — farak shift ke Notes me likha jaata hai.
    /// </summary>
    public decimal? OpeningCash { get; set; }
    public DateOnly ShiftDate { get; set; }
    public long? OperatorEmployeeId { get; set; }
    public bool AllowMeterGap { get; set; }
    public List<TodayShiftOpeningRow> Readings { get; set; } = new();
}

public sealed class TodayShiftOpeningRow
{
    public long NozzleId { get; set; }
    public long ProductId { get; set; }
    public string NozzleCode { get; set; } = string.Empty;
    public string ProductName { get; set; } = string.Empty;
    public decimal OpeningReading { get; set; }
}

/// <summary>
/// "Kitna cash aana chahiye" ke tukde jo is screen ke bahar se aate hain.
///
/// Screen par in-charge sirf AAJ ka cash likhta hai (galle me aaj kitna aaya).
/// ShiftHeaders.ClosingCash me opening jud kar jaata hai — wahi purana niyam, taaki
/// agli shift ki opening pehle jaisi bane.
/// </summary>
public sealed class TodayShiftCashParts
{
    public decimal OpeningCash { get; set; }

    /// <summary>Sales screen ki udhaar parchiyan (is screen ki parchi ke alawa).</summary>
    public decimal OtherCredit { get; set; }

    /// <summary>Sales screen ke UPI / card bill (is screen ke UPI / card ke alawa).</summary>
    public decimal OtherDigital { get; set; }

    public decimal ReceiptsCash { get; set; }
    public decimal CashIn { get; set; }

    /// <summary>Cashbook ka "OUT" — is screen se "malik ko diya" ko chhod kar (wo alag, neeche).</summary>
    public decimal CashOut { get; set; }
    public decimal CashExpenses { get; set; }

    /// <summary>Bank jama — is screen se "bank me jama" ko chhod kar.</summary>
    public decimal BankDeposits { get; set; }

    /// <summary>
    /// Is screen se galle se nikala nakad: malik ko diya / bank me jama. Ye nakad GINNE KE BAAD nikalta hai,
    /// isliye "kitna aana chahiye" me nahi ghatta — sirf "galle me bacha" me ghatta hai.
    /// </summary>
    public decimal HandoverOwner { get; set; }
    public decimal HandoverBank { get; set; }

    /// <summary>Ginne se pehle cash me jo judta/ghatta hai: vasooli + daala − nikala − kharcha − bank (handover chhod kar).</summary>
    public decimal Adjust => ReceiptsCash + CashIn - CashOut - CashExpenses - BankDeposits;
}

public sealed class TodayShiftClosedInfo
{
    public long ShiftId { get; set; }
    public string Label { get; set; } = string.Empty;
    public decimal MeterSale { get; set; }
    public decimal MeterQty { get; set; }

    /// <summary>"350.55 kg + 940.85 L" — alag-alag ikai alag dikhti hain, jodi nahi jaati.</summary>
    public string? QtyText { get; set; }
    public decimal CashExpectedToday { get; set; }
    public decimal CashToday { get; set; }
    public decimal HandedOwner { get; set; }
    public decimal HandedBank { get; set; }

    /// <summary>Galle me bacha nakad — agli shift ki opening yahi banegi.</summary>
    public decimal LeftInDrawer { get; set; }
    public decimal ShortExcess { get; set; }
    public decimal ToleranceRs { get; set; }
    public string? DipNote { get; set; }
}

// ── JSON se aane wale input (fetch) ──────────────────────────────────────

public sealed record TodayShiftSlipInput(long PartyId, decimal Amount, string? VehicleNo, string? SlipNote);

public sealed record TodayShiftMoneyInput(long ShiftId, long PumpId, decimal Upi, decimal Card, List<TodayShiftSlipInput>? Slips);

/// <summary>Galle se nikala nakad. Kind: "OWNER" (malik ko diya) ya "BANK" (bank me jama).</summary>
public sealed record TodayShiftHandoverInput(long ShiftId, long PumpId, string Kind, decimal Amount, string? Note);

public sealed record TodayShiftHandover(long Id, string Kind, decimal Amount, string? Note);

public sealed record TodayShiftExpenseInput(long ShiftId, long PumpId, long ExpenseHeadId, decimal Amount, string? Narration);

public sealed record TodayShiftExpenseDeleteInput(long Id, long ShiftId, long PumpId);

public sealed record TodayShiftReadingInput(long NozzleId, decimal ClosingReading, decimal TestingLoss);

public sealed record TodayShiftDipInput(long TankId, decimal? DipCm, decimal? ActualStock);

public sealed record TodayShiftFinishInput(
    long ShiftId,
    long PumpId,
    List<TodayShiftReadingInput>? Readings,
    List<TodayShiftDipInput>? Dips,
    decimal Upi,
    decimal Card,
    List<TodayShiftSlipInput>? Slips,
    decimal CashToday,
    string? Notes);
