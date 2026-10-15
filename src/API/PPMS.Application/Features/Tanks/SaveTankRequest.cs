namespace PPMS.Application.Features.Tanks;

public sealed record SaveTankRequest(
    long Id,
    long OwnerId,
    long PumpId,
    string Name,
    long ProductId,
    decimal Capacity,
    decimal SafeFillLevel,
    decimal CurrentStock,
    bool IsActive
);
