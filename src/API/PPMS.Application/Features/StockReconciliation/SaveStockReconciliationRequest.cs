namespace PPMS.Application.Features.StockReconciliation;

public sealed record SaveStockReconciliationRequest(
    long OwnerId,
    long PumpId,
    long TankId,
    DateOnly ReconciliationDate,
    decimal BookStock,
    decimal PhysicalStock,
    string? Reason
);
