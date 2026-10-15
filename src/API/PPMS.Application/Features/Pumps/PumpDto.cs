namespace PPMS.Application.Features.Pumps;

public sealed record PumpDto(
    long Id,
    string Name,
    string? City,
    string? Address,
    string? ContactNo,
    string? GSTIN
);
