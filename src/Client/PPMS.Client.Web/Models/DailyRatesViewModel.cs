namespace PPMS.Client.Web.Models;

using PPMS.Client.Web.Services;

/// <summary>
/// "Aaj ke rate" screen. Pump par kai fuel grade hote hain aur roz subah sabka
/// rate alag aata hai — ye screen sabko ek saath dikhati hai taaki har grade ke
/// liye Products form alag se na kholna pade.
/// </summary>
public sealed class DailyRatesViewModel
{
    public long OwnerId { get; set; }
    public long PumpId { get; set; }
    public IReadOnlyList<ApiPumpDto> Pumps { get; set; } = Array.Empty<ApiPumpDto>();
    public List<DailyRateRow> Rates { get; set; } = new();
    public string? Message { get; set; }
    public bool IsError { get; set; }
}

public sealed class DailyRateRow
{
    public long ProductId { get; set; }
    public string Name { get; set; } = string.Empty;
    public string Category { get; set; } = string.Empty;
    public string Unit { get; set; } = string.Empty;
    public string PumpName { get; set; } = string.Empty;

    /// <summary>Abhi chalu rate — yahi form me bharkar aata hai.</summary>
    public decimal CurrentRate { get; set; }

    /// <summary>Screen kholte waqt ka rate. Isse pata chalta hai ki user ne
    /// kis line ko sach me chhua — bina badle wali line API ko bhejni hi nahi.</summary>
    public decimal OriginalRate { get; set; }

    public decimal? PreviousRate { get; set; }
    public DateTime? LastChangedOn { get; set; }
}
