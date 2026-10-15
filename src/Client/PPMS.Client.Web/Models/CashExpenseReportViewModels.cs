using PPMS.Client.Web.Services;

namespace PPMS.Client.Web.Models;

public sealed class CashbookViewModel
{
    public CashbookForm Form { get; set; } = new();
    public IReadOnlyList<ApiPumpDto> Pumps { get; set; } = Array.Empty<ApiPumpDto>();
    /// <summary>Khuli shift(s) — cash entry ko shift se jodne ke liye. Iske bina shift
    /// close ke waqt expected cash me ye cash in/out kabhi count nahi hota tha.</summary>
    public IReadOnlyList<ApiShiftDto> OpenShifts { get; set; } = Array.Empty<ApiShiftDto>();

    /// <summary>
    /// Jin shift se ye entry jod sakte hain — khuli shift pehle, phir haal me
    /// band hui shift.
    ///
    /// Pehle sirf <see cref="OpenShifts"/> dikhti thi, isliye kisi purane (band
    /// ho chuke) din ka kharcha, cash ya dip us din ki shift se jud hi nahi
    /// sakta tha — entry ban jaati thi par ShiftId NULL reh jaata tha.
    /// </summary>
    public IReadOnlyList<ApiShiftDto> LinkableShifts { get; set; } = Array.Empty<ApiShiftDto>();

    public ApiPagedResponse<ApiCashTransactionDto>? Transactions { get; set; }
    public DateTime? FromDate { get; set; }
    public DateTime? ToDate { get; set; }
    public string? SearchTerm { get; set; }
    public int PageNumber { get; set; } = 1;
    public int PageSize { get; set; } = 50;
    public string? Message { get; set; }
}

public sealed class CashbookForm
{
    public long OwnerId { get; set; }
    public long PumpId { get; set; }
    public long? ShiftId { get; set; }
    public string TxnType { get; set; } = "IN";
    public decimal Amount { get; set; }
    public string? ReferenceNo { get; set; }
    public string? Narration { get; set; }
    public DateTime TxnDate { get; set; } = DateTime.Now;
}

public sealed class ExpenseViewModel
{
    public ExpenseForm Form { get; set; } = new();
    public IReadOnlyList<ApiPumpDto> Pumps { get; set; } = Array.Empty<ApiPumpDto>();
    public IReadOnlyList<ApiExpenseHeadDto> Heads { get; set; } = Array.Empty<ApiExpenseHeadDto>();
    public ApiPagedResponse<ApiExpenseDto>? Expenses { get; set; }
    /// <summary>Khuli shift(s) — cash expense ko shift se jodne ke liye.</summary>
    public IReadOnlyList<ApiShiftDto> OpenShifts { get; set; } = Array.Empty<ApiShiftDto>();

    /// <summary>
    /// Jin shift se ye entry jod sakte hain — khuli shift pehle, phir haal me
    /// band hui shift.
    ///
    /// Pehle sirf <see cref="OpenShifts"/> dikhti thi, isliye kisi purane (band
    /// ho chuke) din ka kharcha, cash ya dip us din ki shift se jud hi nahi
    /// sakta tha — entry ban jaati thi par ShiftId NULL reh jaata tha.
    /// </summary>
    public IReadOnlyList<ApiShiftDto> LinkableShifts { get; set; } = Array.Empty<ApiShiftDto>();

    public string? Message { get; set; }

    // Pagination & Search
    public string? SearchTerm { get; set; }
    public DateTime? FromDate { get; set; }
    public DateTime? ToDate { get; set; }
    public int PageNumber { get; set; } = 1;
    public int PageSize { get; set; } = 50;
}

public sealed class ExpenseForm
{
    public long OwnerId { get; set; }
    public long PumpId { get; set; }
    public long? ShiftId { get; set; }
    public long ExpenseHeadId { get; set; }
    public decimal Amount { get; set; }
    public string PaymentMode { get; set; } = "Cash";
    public string? ReferenceNo { get; set; }
    public string? Narration { get; set; }
    public DateTime ExpenseDate { get; set; } = DateTime.Now;
}

public sealed class DayBookViewModel
{
    public DayBookFilter Filter { get; set; } = new();
    public IReadOnlyList<ApiPumpDto> Pumps { get; set; } = Array.Empty<ApiPumpDto>();
    public IReadOnlyList<ApiDayBookEntryDto> Entries { get; set; } = Array.Empty<ApiDayBookEntryDto>();
    public IReadOnlyList<DayBookShiftSummaryRow> ShiftSummaries { get; set; } = Array.Empty<DayBookShiftSummaryRow>();
}

public sealed class DayBookFilter
{
    public long OwnerId { get; set; }
    public long PumpId { get; set; }
    public DateOnly DateFrom { get; set; } = DateOnly.FromDateTime(DateTime.Today.AddDays(-7));
    public DateOnly DateTo { get; set; } = DateOnly.FromDateTime(DateTime.Today);
}

public sealed class DayBookShiftSummaryRow
{
    public long ShiftId { get; set; }
    public DateOnly ShiftDate { get; set; }
    public string ShiftCode { get; set; } = string.Empty;
    public string OperatorName { get; set; } = "-";
    public decimal OpeningCash { get; set; }
    public decimal? ClosingCash { get; set; }
    public decimal SoldQty { get; set; }
    public decimal SoldAmount { get; set; }
    public decimal CashDelta => (ClosingCash ?? 0) - OpeningCash;
    public decimal CashVsMeterVariance => (ClosingCash ?? 0) - OpeningCash - SoldAmount;
}
