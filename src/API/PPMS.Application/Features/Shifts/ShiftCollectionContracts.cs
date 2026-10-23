namespace PPMS.Application.Features.Shifts;

/// <summary>
/// Din ka collection — Phone Pe / Card / udhaar (Section W).
///
/// Din ki bikri meter se banti hai. Wo paisa teen raaston se aata hai: nakad,
/// Phone Pe, aur udhaar. Pehle sirf nakad darj hota tha, isliye har shift me
/// bada "short" dikhta tha — aur us short me asli chori chhup jaati thi.
///
/// Ye ek chhota form hai jisse pump wala ek jagah teenon likh de. Andar wahi
/// SalesHeaders/PartyLedger banti hain jo system pehle se samajhta hai.
/// </summary>
public sealed record ShiftCollectionCreditLine(
    long PartyId,
    string? PartyName,
    decimal Amount,
    // Har parchi alag (Section AK) — kaunsi gaadi, aur chhota note (parchi no. / litre).
    // Default isliye ki purana Collection form bina inke bhi chale.
    string? VehicleNo = null,
    string? SlipNote = null,
    // Section AQ: kaunsa tel aur kitna (litre / kg). ProductName / Unit sirf dikhane ke liye (Get se).
    long? ProductId = null,
    decimal? Quantity = null,
    string? ProductName = null,
    string? Unit = null
);

public sealed record ShiftCollectionDto(
    decimal UpiAmount,
    decimal CardAmount,
    IReadOnlyList<ShiftCollectionCreditLine> Credits
);

public sealed record SaveShiftCollectionRequest(
    long ShiftId,
    decimal UpiAmount,
    decimal CardAmount,
    IReadOnlyList<ShiftCollectionCreditLine> Credits
);

/// <summary>
/// Ek jaisi udhaar ki jaanch (Section AQ4): shift ki parchi (ShiftId) ya party khaate ki entry
/// (EntryDate) ki line - wahi party, wahi din, wahi rakam pehle se ho to wo entry lautti hai.
/// </summary>
public sealed record CreditDuplicateLine(long PartyId, decimal Amount);

public sealed record CreditDuplicateCheckRequest(
    long? ShiftId,
    DateOnly? EntryDate,
    IReadOnlyList<CreditDuplicateLine> Lines
);

/// <summary>NOTE (CLAUDE.md niyam 5): param theek `sp_Credit_FindDuplicates` ke column ke kram / type se.</summary>
public sealed record CreditDuplicateDto(
    long PartyId,
    string PartyName,
    decimal Amount,
    DateTime EntryDate,
    string? ReferenceNo,
    string? Notes
);

public sealed record ShiftCollectionTotalsRow(
    decimal UpiAmount,
    decimal CardAmount
);
