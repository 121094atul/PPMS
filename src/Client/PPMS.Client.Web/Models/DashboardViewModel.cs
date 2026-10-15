using PPMS.Client.Web.Services;

namespace PPMS.Client.Web.Models;

public sealed class DashboardViewModel
{
    public long OwnerId { get; set; }
    public long PumpId { get; set; }
    public string PumpName { get; set; } = "N/A";
    public IReadOnlyList<ApiPumpDto> Pumps { get; set; } = Array.Empty<ApiPumpDto>();

    public decimal TotalSalesAmount { get; set; }
    public decimal TodaySalesAmount { get; set; }
    public decimal TotalExpenseAmount { get; set; }
    public decimal TodayExpenseAmount { get; set; }
    public decimal OutstandingAmount { get; set; }
    public int OpenShiftCount { get; set; }
    public int ActiveOperatorCount { get; set; }
    public int ActivePartyCount { get; set; }

    public IReadOnlyList<ApiSaleDto> RecentSales { get; set; } = Array.Empty<ApiSaleDto>();
    public IReadOnlyList<ApiOutstandingPartyDto> TopOutstanding { get; set; } = Array.Empty<ApiOutstandingPartyDto>();
    public IReadOnlyList<ApiShiftDto> OpenShifts { get; set; } = Array.Empty<ApiShiftDto>();
    public IReadOnlyList<ApiTankDto> LowStockTanks { get; set; } = Array.Empty<ApiTankDto>();

    /// <summary>
    /// Har chaalu tank — chahe uska stock theek ho ya kam.
    ///
    /// Pehle dashboard sirf <see cref="LowStockTanks"/> dikhata tha, isliye jab
    /// sab tank theek hote the to "kitna tel hai" kahin dikhta hi nahi tha —
    /// bas ek hari lakeer. Pump wale ke liye ye pehla sawaal hota hai, isliye
    /// ab poori list bheji jaati hai.
    /// </summary>
    public IReadOnlyList<ApiTankDto> AllTanks { get; set; } = Array.Empty<ApiTankDto>();

    public string SelectedMonthYear { get; set; } = "";
    public string SelectedMonthLabel { get; set; } = "MONTH";
    public List<(string Value, string Label)> AvailableMonths { get; set; } = new();

    /// <summary>
    /// Pichhle 15 din me jin dino ka koi shift/sale record hi nahi hai.
    /// Pump wale kai baar kuch din entry karna bhool jaate hain — ye list unhe
    /// yaad dilati hai ki kaun kaun se din bharne baaki hain.
    /// </summary>
    public IReadOnlyList<MissingEntryDay> MissingDays { get; set; } = Array.Empty<MissingEntryDay>();

    /// <summary>
    /// Naya pump pehle din login karta hai to use sirf zero aur ek daraawna
    /// "Low Tank Stock Alert" dikhta tha — aage kya karna hai iska koi raasta nahi.
    /// Ye list wahi raasta hai: kya ho chuka, kya baaki. Sab ho jaane par apne aap
    /// gayab ho jaati hai.
    /// </summary>
    public SetupStatus Setup { get; set; } = new();
}

public sealed class SetupStatus
{
    public bool HasProducts { get; set; }
    public bool HasTanks { get; set; }
    public bool HasNozzles { get; set; }
    public bool HasOpeningStock { get; set; }
    public bool HasRates { get; set; }
    public bool HasAnyShift { get; set; }

    /// <summary>Tank me stock daala hi nahi gaya — "kam stock" ka alarm bekaar hai.</summary>
    public bool StockNeverEntered => !HasOpeningStock;

    public int DoneCount =>
        (HasProducts ? 1 : 0) + (HasTanks ? 1 : 0) + (HasNozzles ? 1 : 0) +
        (HasRates ? 1 : 0) + (HasOpeningStock ? 1 : 0) + (HasAnyShift ? 1 : 0);

    public const int TotalSteps = 6;

    /// <summary>Sab ho gaya to checklist dikhane ka koi matlab nahi.</summary>
    public bool IsComplete => DoneCount >= TotalSteps;
}

public sealed record MissingEntryDay(DateOnly Date, bool HasShift, bool HasSale)
{
    public string Label => Date.ToString("ddd, dd MMM");
    public int DaysAgo => DateOnly.FromDateTime(DateTime.Today).DayNumber - Date.DayNumber;
}
