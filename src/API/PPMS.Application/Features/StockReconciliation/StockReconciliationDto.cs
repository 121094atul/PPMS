namespace PPMS.Application.Features.StockReconciliation;

public sealed record StockReconciliationDto(
    long Id,
    long OwnerId,
    long PumpId,
    long TankId,
    string TankName,
    DateTime ReconciliationDate,
    decimal BookStock,
    decimal PhysicalStock,
    decimal VarianceQty,
    decimal? VarianceAmount,
    string? Reason,
    DateTime CreatedOn
);
