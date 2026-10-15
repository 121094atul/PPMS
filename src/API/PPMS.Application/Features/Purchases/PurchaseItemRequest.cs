using System.Text.Json.Serialization;

namespace PPMS.Application.Features.Purchases;

/// <summary>
/// Khareed ki ek line.
///
/// <para><b>Amount</b> = is product ki BILL wali rakam (VAT, recovery sab mila
/// kar). Yahi sach hai — Sale / Purchase Register isi se banta hai. Pehle sirf
/// Rate aata tha aur rakam Quantity x Rate se banti thi: 2 ank ke rate se bill
/// ki rakam kabhi nahi milti thi (Section AE).</para>
///
/// <para><b>Rate</b> ab sirf purane client ke liye hai — jo Amount nahi bhejta,
/// uski rakam pehle jaisi Quantity x Rate. Amount aakhir me aur optional hai,
/// isliye purana JSON bina badle chalta hai.</para>
/// </summary>
public sealed record PurchaseItemRequest(
    long ProductId,
    long? TankId,
    decimal Quantity,
    decimal Rate,
    decimal? Amount = null
)
{
    /// <summary>Is line ki rakam — bill wali ho to wahi, warna Quantity x Rate.</summary>
    [JsonIgnore]
    public decimal LineAmount => Amount is > 0
        ? decimal.Round(Amount.Value, 2, MidpointRounding.AwayFromZero)
        : decimal.Round(Quantity * Rate, 2, MidpointRounding.AwayFromZero);

    /// <summary>Prati litre rate — rakam se nikala hua (4 ank).</summary>
    [JsonIgnore]
    public decimal LineRate => Quantity > 0
        ? decimal.Round(LineAmount / Quantity, 4, MidpointRounding.AwayFromZero)
        : Rate;
}
