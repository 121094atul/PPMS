using PPMS.Client.Web.Services;

namespace PPMS.Client.Web.Models;

/// <summary>
/// "Din ka collection" screen (Section W).
///
/// Din ki bikri meter se banti hai, par paisa teen raaston se aata hai — nakad,
/// online, aur udhaar. Sirf nakad darj hone se har shift me bada "short" dikhta
/// tha, aur us short me asli chori chhup jaati thi.
///
/// Ye form us khaai ko bharta hai: ek jagah online, card aur udhaar likh do.
/// </summary>
public sealed class ShiftCollectionViewModel
{
    public long ShiftId { get; set; }
    public long PumpId { get; set; }

    /// <summary>Screen par dikhne wala shift ka naam — "01 Sep 2026 · Shift 1".</summary>
    public string ShiftLabel { get; set; } = string.Empty;

    public decimal MeterSale { get; set; }
    public decimal CashEntered { get; set; }

    public ShiftCollectionForm Form { get; set; } = new();

    /// <summary>Udhaar ke dropdown ke liye — is pump ke credit customer.</summary>
    public IReadOnlyList<ApiPartyDto> Parties { get; set; } = Array.Empty<ApiPartyDto>();

    public string? Message { get; set; }
    public bool IsError { get; set; }

    /// <summary>
    /// Jo paisa nakad me nahi aaya. Iske ghatne ke baad jo bache, wahi nakad
    /// hona chahiye — user ko yahi ganit screen par dikhta hai.
    /// </summary>
    public decimal NonCashTotal =>
        Form.UpiAmount + Form.CardAmount + Form.Credits.Sum(x => x.Amount);

    public decimal ExpectedCash => MeterSale - NonCashTotal;

    public decimal Difference => CashEntered - ExpectedCash;
}

public sealed class ShiftCollectionForm
{
    public long ShiftId { get; set; }

    /// <summary>PhonePe / GPay / Paytm — sab isi me.</summary>
    public decimal UpiAmount { get; set; }

    public decimal CardAmount { get; set; }

    public List<ShiftCollectionCreditForm> Credits { get; set; } = new();
}

public sealed class ShiftCollectionCreditForm
{
    public long PartyId { get; set; }
    public decimal Amount { get; set; }

    // Har parchi alag (Section AK). Yahan dobara save karne par ye mit na jaayen,
    // isliye form me saath chalte hain.
    public string? VehicleNo { get; set; }
    public string? SlipNote { get; set; }

    // Section AQ: kaunsa tel aur kitna - saath chalte hain, ProductLabel sirf dikhane ko ("20 L Diesel").
    public long? ProductId { get; set; }
    public decimal? Quantity { get; set; }
    public string? ProductLabel { get; set; }
}
