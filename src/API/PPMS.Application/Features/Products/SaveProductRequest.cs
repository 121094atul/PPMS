namespace PPMS.Application.Features.Products;

public sealed record SaveProductRequest(
    long? Id,
    long OwnerId,
    long PumpId,
    string Name,
    string Category,
    string Unit,
    decimal CurrentRate,
    string? HSNCode,
    decimal CGSTRate,
    decimal SGSTRate
);
