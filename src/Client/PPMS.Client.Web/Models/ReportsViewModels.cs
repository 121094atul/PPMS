using PPMS.Client.Web.Services;

namespace PPMS.Client.Web.Models;

public sealed class ReportsHomeViewModel
{
    public IReadOnlyList<ApiPumpDto> Pumps { get; set; } = Array.Empty<ApiPumpDto>();
    public long PumpId { get; set; }
    public DateOnly DateFrom { get; set; } = DateOnly.FromDateTime(DateTime.Today.AddDays(-7));
    public DateOnly DateTo { get; set; } = DateOnly.FromDateTime(DateTime.Today);
    /// <summary>Munafa ka card sirf usko jise "/profit-loss" menu mila hai (Section AO).</summary>
    public bool ShowProfitLoss { get; set; }
    /// <summary>Financials ka card - "/financials" menu wale ko (Section AP).</summary>
    public bool ShowFinancials { get; set; }
}

public sealed class OutstandingReportViewModel
{
    public long OwnerId { get; set; }
    public long PumpId { get; set; }
    public IReadOnlyList<ApiPumpDto> Pumps { get; set; } = Array.Empty<ApiPumpDto>();
    public IReadOnlyList<ApiOutstandingPartyDto> Items { get; set; } = Array.Empty<ApiOutstandingPartyDto>();
}

public sealed class PumpComparisonReportViewModel
{
    public long OwnerId { get; set; }
    public DateOnly DateFrom { get; set; } = DateOnly.FromDateTime(DateTime.Today.AddDays(-7));
    public DateOnly DateTo { get; set; } = DateOnly.FromDateTime(DateTime.Today);
    public IReadOnlyList<ApiPumpComparisonDto> Items { get; set; } = Array.Empty<ApiPumpComparisonDto>();
}

/// <summary>
/// Maahwar bikri-khareed register (Section AD) — owner ke haath se likhe
/// rajistar jaisa: ek mahina, ek product, chhe khaane.
/// </summary>
public sealed class SalePurchaseRegisterViewModel
{
    public long PumpId { get; set; }
    public long ProductId { get; set; }
    public int Month { get; set; } = DateTime.Today.Month;
    public int Year { get; set; } = DateTime.Today.Year;

    public IReadOnlyList<ApiPumpDto> Pumps { get; set; } = Array.Empty<ApiPumpDto>();
    public IReadOnlyList<ApiProductDto> Products { get; set; } = Array.Empty<ApiProductDto>();
    public IReadOnlyList<ApiMonthlySaleRegisterRow> Items { get; set; } = Array.Empty<ApiMonthlySaleRegisterRow>();
}

public sealed class DailyStockRegisterViewModel
{
    public long PumpId { get; set; }
    public long ProductId { get; set; }
    public int Month { get; set; } = DateTime.Today.Month;
    public int Year { get; set; } = DateTime.Today.Year;
    
    public IReadOnlyList<ApiPumpDto> Pumps { get; set; } = Array.Empty<ApiPumpDto>();
    public IReadOnlyList<ApiProductDto> Products { get; set; } = Array.Empty<ApiProductDto>();
    public IReadOnlyList<ApiDailyStockRegisterDto> Items { get; set; } = Array.Empty<ApiDailyStockRegisterDto>();
}
