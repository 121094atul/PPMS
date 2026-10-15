namespace PPMS.Application.Features.PartyLedger;

// PUMP.sp_PartyLedger_Statement (Section AF) ke do result set. Dono positional record hain —
// SP me column jode ya kram badle to yahan bhi usi waqt badalna hai.

/// <summary>
/// Party ka hisaab ek nazar me:  OpeningBalance + TotalDebit - TotalCredit = LedgerBalance.
/// LedgerBalance aur CurrentBalance barabar hone chahiye; alag hon to record bigda hai
/// (Support Console ka "Recount" use theek karta hai).
///
/// OpeningBalance yahan "jo baki us din bhara gaya tha" hai (Section AH), Parties ka
/// rakha hua OpeningBalance column nahi:
///   OpeningAsOf  — baki aakhri baar haath se kab bhara gaya (party banate waqt, ya form se badal kar)
///   EarlierCount — us se PEHLE bani line; wo bhare hue baki me shaamil hain, list me nahi aati
///   EarlierNet   — un line ka jod (sirf jaankari ke liye)
/// </summary>
public sealed record PartyStatementHeaderDto(
    long PartyId,
    string PartyName,
    decimal OpeningBalance,
    decimal TotalDebit,
    decimal TotalCredit,
    decimal CurrentBalance,
    decimal LedgerBalance,
    int TotalCount,
    DateTime? OpeningAsOf,
    int EarlierCount,
    decimal EarlierNet
);

/// <summary>
/// SignedAmount: + = baki badha (udhaar), - = baki ghata (jama).
/// RunningBalance: is line ke BAAD ka baki, purane baki se shuru karke.
/// CanEdit: Party Ledger form se haath se bani entry (Section AI) — sirf ise badla / hataya
/// ja sakta hai. Din ke collection / bill wali line wahin se badalti hai.
/// </summary>
public sealed record PartyStatementLineDto(
    long Id,
    DateTime EntryDateTime,
    string EntryType,
    decimal Amount,
    string ReferenceNo,
    string Notes,
    string PaymentMode,
    decimal SignedAmount,
    decimal RunningBalance,
    bool CanEdit
);

public sealed record PartyStatementDto(
    PartyStatementHeaderDto Header,
    IReadOnlyList<PartyStatementLineDto> Lines,
    int PageNumber,
    int PageSize
);
