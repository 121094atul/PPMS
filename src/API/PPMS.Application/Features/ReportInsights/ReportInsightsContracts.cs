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

public interface IReportInsightsRepository
{
    Task<IReadOnlyList<OutstandingPartyDto>> GetOutstandingAsync(long ownerId, long pumpId, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<PumpComparisonDto>> GetPumpComparisonAsync(long ownerId, DateOnly dateFrom, DateOnly dateTo, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<DailyStockRegisterDto>> GetDailyStockRegisterAsync(long pumpId, long productId, int month, int year, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<MonthlySaleRegisterDto>> GetMonthlySaleRegisterAsync(long pumpId, long productId, int month, int year, long ownerId, CancellationToken cancellationToken = default);
}

public interface IReportInsightsService
{
    Task<IReadOnlyList<OutstandingPartyDto>> GetOutstandingAsync(long ownerId, long pumpId, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<PumpComparisonDto>> GetPumpComparisonAsync(long ownerId, DateOnly dateFrom, DateOnly dateTo, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<DailyStockRegisterDto>> GetDailyStockRegisterAsync(long pumpId, long productId, int month, int year, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<MonthlySaleRegisterDto>> GetMonthlySaleRegisterAsync(long pumpId, long productId, int month, int year, long ownerId, CancellationToken cancellationToken = default);
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
}
