using PPMS.Client.Web.Services;

namespace PPMS.Client.Web.Models;

/// <summary>
/// Super Admin ka support console (Section Z).
///
/// Grahak ka phone aata hai — "galti se shift band kar di", "khaali shift ban
/// gayi". Ab tak in dono ka ek hi ilaaj tha: developer database me ghuse aur
/// haath se SQL chalaye. Ye screen wahi do kaam, jaanch ke saath, screen par
/// le aati hai.
///
/// Yahan OwnerId JWT se NAHI aata — support wala kisi bhi owner ka data theek
/// karta hai. Isliye har action par Super Admin ki jaanch hai (client par bhi,
/// API par bhi).
/// </summary>
public sealed class SupportConsoleViewModel
{
    public IReadOnlyList<ApiOwnerDto> Owners { get; set; } = Array.Empty<ApiOwnerDto>();

    public long SelectedOwnerId { get; set; }
    public long SelectedPumpId { get; set; }

    /// <summary>Kitne din peeche tak ki shift dikhani hai.</summary>
    public int Days { get; set; } = 60;

    public IReadOnlyList<ApiSupportShiftDto> Shifts { get; set; } = Array.Empty<ApiSupportShiftDto>();

    /// <summary>
    /// Meter ki tooti hui kadi — wahi jaanch jo owner apne Shifts page par dekhta
    /// hai, bas yahan support kisi bhi owner ke liye chala sakta hai.
    /// </summary>
    public IReadOnlyList<ApiMeterChainGap> MeterChainGaps { get; set; } = Array.Empty<ApiMeterChainGap>();

    public string? Message { get; set; }
    public bool IsError { get; set; }

    public string SelectedOwnerName =>
        Owners.FirstOrDefault(x => x.Id == SelectedOwnerId)?.Name ?? string.Empty;
}
