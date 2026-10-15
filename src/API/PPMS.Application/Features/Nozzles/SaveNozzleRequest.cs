namespace PPMS.Application.Features.Nozzles;

public sealed record SaveNozzleRequest(
    long? Id,
    long OwnerId,
    long PumpId,
    long ProductId,
    string NozzleCode,
    long? TankId
);
