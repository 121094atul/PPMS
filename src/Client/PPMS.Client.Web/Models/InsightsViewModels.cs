using PPMS.Client.Web.Services;

namespace PPMS.Client.Web.Models;

/// <summary>
/// Munafa (P&amp;L) report - Section AO1. Bikri - kharid = margin; margin - kharcha - salary = shuddh munafa.
/// Jis product ki kharid ka rate mila hi nahi (CostSource NONE), uska margin nahi jodte - warna poori
/// bikri munafa dikhti.
/// </summary>
public sealed class ProfitLossViewModel
{
    public IReadOnlyList<ApiPumpDto> Pumps { get; set; } = Array.Empty<ApiPumpDto>();
    public long PumpId { get; set; }
    public DateOnly DateFrom { get; set; }
    public DateOnly DateTo { get; set; }

    public IReadOnlyList<ApiProfitLossLineDto> Sales { get; set; } = Array.Empty<ApiProfitLossLineDto>();
    public IReadOnlyList<ApiProfitLossLineDto> Expenses { get; set; } = Array.Empty<ApiProfitLossLineDto>();
    public decimal Salary { get; set; }

    public decimal TotalSale => Sales.Sum(x => x.Amount);
    /// <summary>Sirf un product ki bikri jinka kharid rate mila - margin isi par banta hai.</summary>
    public decimal CostedSale => Sales.Where(x => x.CostAmount is not null).Sum(x => x.Amount);
    public decimal TotalCost => Sales.Sum(x => x.CostAmount ?? 0);
    public decimal GrossMargin => CostedSale - TotalCost;
    public decimal TotalExpenses => Expenses.Sum(x => x.Amount);
    public decimal NetProfit => GrossMargin - TotalExpenses - Salary;
    public bool AnyCostMissing => Sales.Any(x => x.CostAmount is null);
}

/// <summary>
/// GST report - Section AW. Dar-wise jod, HSN summary (GSTR-1), har GST bill (GSTIN ho to B2B),
/// aur GST ke bahar ki bikri (petrol / diesel / CNG - GSTR-3B 3.1(e)).
/// </summary>
public sealed class GstReportViewModel
{
    public IReadOnlyList<ApiPumpDto> Pumps { get; set; } = Array.Empty<ApiPumpDto>();
    public long PumpId { get; set; }
    public string? PumpGstin { get; set; }
    public DateOnly DateFrom { get; set; }
    public DateOnly DateTo { get; set; }

    public IReadOnlyList<ApiGstLineDto> Rates { get; set; } = Array.Empty<ApiGstLineDto>();
    public IReadOnlyList<ApiGstLineDto> Hsn { get; set; } = Array.Empty<ApiGstLineDto>();
    public IReadOnlyList<ApiGstLineDto> Bills { get; set; } = Array.Empty<ApiGstLineDto>();
    public IReadOnlyList<ApiGstLineDto> NonGst { get; set; } = Array.Empty<ApiGstLineDto>();

    public decimal Taxable => Rates.Sum(x => x.TaxableValue);
    public decimal Cgst => Rates.Sum(x => x.Cgst);
    public decimal Sgst => Rates.Sum(x => x.Sgst);
    public decimal Igst => Rates.Sum(x => x.Igst);
    public decimal TotalTax => Cgst + Sgst + Igst;
    /// <summary>Bill ki asli rakam ka jod - Taxable + TotalTax paise ke rounding se 1 paisa kam aa sakta hai.</summary>
    public decimal GrandTotal => Rates.Sum(x => x.Total);
    public decimal NonGstTotal => NonGst.Sum(x => x.Total);
    public int B2bCount => Bills.Count(x => !string.IsNullOrWhiteSpace(x.PartyGstin));

    /// <summary>GSTR-1 ka UQC: Litre -> LTR, Kg -> KGS, baaki NOS.</summary>
    public static string Uqc(string? unit) => (unit ?? string.Empty).Trim().ToLowerInvariant() switch
    {
        "litre" or "liter" or "ltr" or "l" => "LTR",
        "kg" or "kgs" => "KGS",
        _ => "NOS"
    };
}

/// <summary>
/// Financials - Section AP. Aaj ki haalat (stock, udhaar, galla) aur chuni tareekh me paisa kahan gaya.
/// SP code (STOCK_VALUE, TO_OWNER...) bhejta hai; yahan unhe naam se padhte hain.
/// </summary>
public sealed class FinancialsViewModel
{
    public IReadOnlyList<ApiPumpDto> Pumps { get; set; } = Array.Empty<ApiPumpDto>();
    public long PumpId { get; set; }
    public DateOnly DateFrom { get; set; }
    public DateOnly DateTo { get; set; }

    public IReadOnlyList<ApiFinancialLineDto> Lines { get; set; } = Array.Empty<ApiFinancialLineDto>();
    public IReadOnlyList<ApiFinancialLineDto> Stock => Lines.Where(x => x.Section == "STOCK").OrderBy(x => x.SortOrder).ToList();
    public IReadOnlyList<ApiFinancialLineDto> TopDues => Lines.Where(x => x.Section == "RECEIVABLE_TOP").OrderBy(x => x.SortOrder).ToList();

    public decimal Position(string code) => Lines.FirstOrDefault(x => x.Section == "POSITION" && x.Name == code)?.Amount ?? 0;
    public int ReceivableParties => (int)(Lines.FirstOrDefault(x => x.Section == "POSITION" && x.Name == "RECEIVABLE")?.Qty ?? 0);
    public decimal Flow(string code) => Lines.FirstOrDefault(x => x.Section == "FLOW" && x.Name == code)?.Amount ?? 0;

    public decimal TotalSale => Flow("METER_SALE") + Flow("COUNTER_SALE");
    /// <summary>Bikri me se jo nakad me aaya: kul - udhaar - UPI / card.</summary>
    public decimal CashSale => TotalSale - Flow("CREDIT_GIVEN") - Flow("DIGITAL");
}

/// <summary>Activity Log - Section AO2. AuditLog ki lines, nayi upar.</summary>
public sealed class ActivityLogViewModel
{
    public DateOnly DateFrom { get; set; }
    public DateOnly DateTo { get; set; }
    public string? Area { get; set; }
    public int PageNumber { get; set; } = 1;
    // Phone par 100 line lambi thi (owner, 2026-10-23).
    public int PageSize { get; set; } = 50;
    public int TotalCount { get; set; }
    public IReadOnlyList<ApiAuditLogEntryDto> Items { get; set; } = Array.Empty<ApiAuditLogEntryDto>();
    public IReadOnlyDictionary<long, string> PumpNames { get; set; } = new Dictionary<long, string>();

    public int PageCount => TotalCount == 0 ? 1 : (int)Math.Ceiling(TotalCount / (double)PageSize);
}
