namespace PPMS.Application.Features.Tanks;

public sealed record TankDto(
    long Id,
    long PumpId,
    string Name,
    long ProductId,
    string ProductName,
    string Unit,
    decimal Capacity,
    decimal SafeFillLevel,
    decimal CurrentStock,
    bool IsActive
);
