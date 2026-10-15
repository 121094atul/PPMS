namespace PPMS.Application.Features.Purchases;

public sealed record PurchaseDetailDto(
    long Id,
    long OwnerId,
    long PumpId,
    long VendorId,
    string InvoiceNo,
    DateOnly InvoiceDate,
    string? VehicleNo,
    string? DriverName,
    string? Notes,
    List<PurchaseDetailItemDto> Items
);

/// <summary>
/// NOTE (CLAUDE.md niyam 5): param theek GetByIdAsync ki doosri SELECT ke column
/// ke kram/type se milte hain — ProductId, TankId, Quantity, Rate, Amount.
/// </summary>
public sealed record PurchaseDetailItemDto(
    long ProductId,
    long? TankId,
    decimal Quantity,
    decimal Rate,
    decimal Amount
);
