namespace PPMS.Application.Features.Products;

public sealed record ProductDto(
    long Id,
    long PumpId,
    string Name,
    string Category,
    string Unit,
    decimal CurrentRate,
    string? HSNCode,
    decimal CGSTRate,
    decimal SGSTRate
);

public sealed record ProductRateHistoryDto(
    long Id,
    long ProductId,
    decimal OldRate,
    decimal NewRate,
    DateTime ChangedAt,
    long? ChangedBy
);
