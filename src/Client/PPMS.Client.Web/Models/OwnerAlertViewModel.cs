using PPMS.Client.Web.Services;

namespace PPMS.Client.Web.Models;

/// <summary>
/// Settings &gt; Alerts — owner khud tay karta hai ki kaunsa sandesh chahiye aur
/// kis number par.
///
/// <para>Ye screen isliye zaroori hai: app cheh jagah owner ko alert bhejti hai,
/// par ab tak wo number kahin set hi nahi hota tha. Purana code DB se KISI BHI
/// pump ke malik ka number utha leta tha (OwnerId ka filter hi nahi tha) — wo
/// security review me hata diya gaya, aur uske baad ye cheho alert band pade the.</para>
///
/// <para>Har alert ka apna switch isliye hai ki WhatsApp par har sandesh ka paisa
/// lagta hai — jo alert nahi chahiye, owner use band kar de.</para>
/// </summary>
public sealed class OwnerAlertViewModel
{
    /// <summary>Alert kis number par jayein. Khaali ho to koi alert nahi jayega.</summary>
    public string? Mobile { get; set; }

    public IReadOnlyList<ApiOwnerAlertDto> Alerts { get; set; } = Array.Empty<ApiOwnerAlertDto>();

    public string? Message { get; set; }

    /// <summary>Message laal dikhana hai ya hara.</summary>
    public bool IsError { get; set; }
}
