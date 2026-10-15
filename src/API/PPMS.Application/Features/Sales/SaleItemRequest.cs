namespace PPMS.Application.Features.Sales;

public sealed record SaleItemRequest(
    long ProductId,
    string? NozzleNo,
    decimal Quantity,
    decimal Rate,
    decimal BaseAmount,
    decimal CGSTAmount,
    decimal SGSTAmount
);
