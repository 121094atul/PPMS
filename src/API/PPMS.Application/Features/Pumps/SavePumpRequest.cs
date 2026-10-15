namespace PPMS.Application.Features.Pumps;

public sealed record SavePumpRequest(
    long? Id,
    long OwnerId,
    string Name,
    string? City,
    string? Address,
    string? ContactNo,
    string? GSTIN
);
