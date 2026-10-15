namespace PPMS.Application.Features.Nozzles;

public sealed record NozzleDto(
    long Id,
    long OwnerId,
    long PumpId,
    long ProductId,
    string ProductName,
    string NozzleCode,
    long? TankId,
    bool IsActive
);
