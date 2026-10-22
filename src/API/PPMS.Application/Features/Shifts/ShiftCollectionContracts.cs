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
    string? SlipNote = null
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

public sealed record ShiftCollectionTotalsRow(
    decimal UpiAmount,
    decimal CardAmount
);
