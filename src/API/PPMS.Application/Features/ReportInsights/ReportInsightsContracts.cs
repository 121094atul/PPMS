namespace PPMS.Application.Features.ReportInsights;

public sealed record OutstandingPartyDto(
    long PartyId,
    string PartyName,
    string PartyType,
    decimal CreditLimit,
    decimal CurrentBalance,
    DateTime? LastSaleDate
);

/// <summary>
/// Maahwar bikri-khareed register ki ek line (Section AD) — owner ke haath se
/// likhe rajistar jaisa: dinaank, bikri, rate, total, khareed.
///
/// NOTE (CLAUDE.md niyam 5): param theek `sp_Report_MonthlySaleRegister` ke
/// column ke kram, naam aur type se milte hain.
/// </summary>
public sealed record MonthlySaleRegisterDto(
    int DayOfMonth,
    DateTime Date,
    decimal SaleQty,
    decimal Rate,
    decimal SaleAmount,
    decimal PurchaseQty,
    decimal PurchaseAmount
);

public sealed record PumpComparisonDto(
    long PumpId,
    string PumpName,
    string? City,
    decimal SalesAmount,
    decimal PurchaseAmount,
    decimal ExpenseAmount,
    decimal NetAmount
);

public sealed record DailyStockRegisterDto(
    int DayOfMonth,
    DateTime Date,
    decimal OpeningStock,
    decimal Receipt,
    decimal TotalStock,
    decimal SalesByMeter,
    decimal PumpTest,
    decimal NetSalesByMeter,
    decimal CumulativeSales,
    decimal SalesByDip,
    // Kitaabi closing (opening + receipt - net sale) aur asli napa hua stock -
    // dono alag. Pehle sirf ClosingStock tha jo chupke se dip par switch ho
    // jaata tha, isliye CA ko variance ka aadhaar dikhta hi nahi tha.
    decimal BookClosingStock,
    // Jis din stock napa nahi gaya us din NULL (report me "-").
    decimal? PhysicalClosingStock,
    bool StockChecked,
    decimal ClosingStock,
    decimal VariationDaily,
    decimal VariationValue,
    decimal VariationCumulative,
    // Us din ka rate aur us hisaab se bikri ki value.
    decimal RateApplied,
    decimal SalesValue,
    decimal CumulativeSalesValue,
    string? Remarks
);

/// <summary>
/// Munafa report ki ek line (Section AO1). Section: SALE (product-wise bikri + kharid), EXPENSE (kharche
/// ka head), SALARY. Kharid rate na mile to CostRate / CostAmount null aur CostSource 'NONE'.
///
/// NOTE (CLAUDE.md niyam 5): param theek `sp_Report_ProfitLoss` ke column ke kram, naam aur type se.
/// </summary>
public sealed record ProfitLossLineDto(
    string Section,
    int SortOrder,
    long? ItemId,
    string Name,
    string? Unit,
    decimal Qty,
    decimal Amount,
    decimal? CostRate,
    decimal? CostAmount,
    string CostSource
);

/// <summary>
/// Activity Log ki ek line (Section AO2) - AuditLog se. Detail: shift ka din + code ya party ka naam.
///
/// NOTE (CLAUDE.md niyam 5): param theek `sp_AuditLog_List` ke column ke kram, naam aur type se.
/// </summary>
public sealed record AuditLogEntryDto(
    long Id,
    DateTime CreatedOn,
    long? PumpId,
    string? UserName,
    string EntityName,
    long? EntityId,
    string Action,
    string? Reason,
    string? OldValues,
    string? NewValues,
    string? Detail,
    string Area,
    int TotalCount
);

/// <summary>
/// Financials ki ek line (Section AP). Section: POSITION / FLOW (Name = code, jaise STOCK_VALUE,
/// TO_OWNER), STOCK (har tank), RECEIVABLE_TOP (party). Note: STOCK me rate kahan se (PURCHASE / SALE_RATE).
///
/// NOTE (CLAUDE.md niyam 5): param theek `sp_Report_Financials` ke column ke kram, naam aur type se.
/// </summary>
public sealed record FinancialLineDto(
    string Section,
    int SortOrder,
    string Name,
    decimal? Qty,
    decimal? Rate,
    decimal Amount,
    string? Note
);

public interface IReportInsightsRepository
{
    Task<IReadOnlyList<OutstandingPartyDto>> GetOutstandingAsync(long ownerId, long pumpId, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<PumpComparisonDto>> GetPumpComparisonAsync(long ownerId, DateOnly dateFrom, DateOnly dateTo, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<DailyStockRegisterDto>> GetDailyStockRegisterAsync(long pumpId, long productId, int month, int year, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<MonthlySaleRegisterDto>> GetMonthlySaleRegisterAsync(long pumpId, long productId, int month, int year, long ownerId, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<ProfitLossLineDto>> GetProfitLossAsync(long ownerId, long pumpId, DateOnly dateFrom, DateOnly dateTo, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<AuditLogEntryDto>> GetActivityLogAsync(long ownerId, DateOnly dateFrom, DateOnly dateTo, string? area, int pageNumber, int pageSize, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<FinancialLineDto>> GetFinancialsAsync(long ownerId, long pumpId, DateOnly dateFrom, DateOnly dateTo, CancellationToken cancellationToken = default);
}

public interface IReportInsightsService
{
    Task<IReadOnlyList<OutstandingPartyDto>> GetOutstandingAsync(long ownerId, long pumpId, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<PumpComparisonDto>> GetPumpComparisonAsync(long ownerId, DateOnly dateFrom, DateOnly dateTo, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<DailyStockRegisterDto>> GetDailyStockRegisterAsync(long pumpId, long productId, int month, int year, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<MonthlySaleRegisterDto>> GetMonthlySaleRegisterAsync(long pumpId, long productId, int month, int year, long ownerId, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<ProfitLossLineDto>> GetProfitLossAsync(long ownerId, long pumpId, DateOnly dateFrom, DateOnly dateTo, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<AuditLogEntryDto>> GetActivityLogAsync(long ownerId, DateOnly dateFrom, DateOnly dateTo, string? area, int pageNumber, int pageSize, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<FinancialLineDto>> GetFinancialsAsync(long ownerId, long pumpId, DateOnly dateFrom, DateOnly dateTo, CancellationToken cancellationToken = default);
}

public sealed class ReportInsightsService(IReportInsightsRepository repository) : IReportInsightsService
{
    public Task<IReadOnlyList<OutstandingPartyDto>> GetOutstandingAsync(long ownerId, long pumpId, CancellationToken cancellationToken = default)
        => repository.GetOutstandingAsync(ownerId, pumpId, cancellationToken);

    public Task<IReadOnlyList<PumpComparisonDto>> GetPumpComparisonAsync(long ownerId, DateOnly dateFrom, DateOnly dateTo, CancellationToken cancellationToken = default)
        => repository.GetPumpComparisonAsync(ownerId, dateFrom, dateTo, cancellationToken);

    public Task<IReadOnlyList<DailyStockRegisterDto>> GetDailyStockRegisterAsync(long pumpId, long productId, int month, int year, CancellationToken cancellationToken = default)
        => repository.GetDailyStockRegisterAsync(pumpId, productId, month, year, cancellationToken);

    public Task<IReadOnlyList<MonthlySaleRegisterDto>> GetMonthlySaleRegisterAsync(long pumpId, long productId, int month, int year, long ownerId, CancellationToken cancellationToken = default)
        => repository.GetMonthlySaleRegisterAsync(pumpId, productId, month, year, ownerId, cancellationToken);

    public Task<IReadOnlyList<ProfitLossLineDto>> GetProfitLossAsync(long ownerId, long pumpId, DateOnly dateFrom, DateOnly dateTo, CancellationToken cancellationToken = default)
        => repository.GetProfitLossAsync(ownerId, pumpId, dateFrom, dateTo, cancellationToken);

    public Task<IReadOnlyList<AuditLogEntryDto>> GetActivityLogAsync(long ownerId, DateOnly dateFrom, DateOnly dateTo, string? area, int pageNumber, int pageSize, CancellationToken cancellationToken = default)
        => repository.GetActivityLogAsync(ownerId, dateFrom, dateTo, area, pageNumber, pageSize, cancellationToken);

    public Task<IReadOnlyList<FinancialLineDto>> GetFinancialsAsync(long ownerId, long pumpId, DateOnly dateFrom, DateOnly dateTo, CancellationToken cancellationToken = default)
        => repository.GetFinancialsAsync(ownerId, pumpId, dateFrom, dateTo, cancellationToken);
}
