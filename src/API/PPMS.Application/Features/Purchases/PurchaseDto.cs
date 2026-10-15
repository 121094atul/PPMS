namespace PPMS.Application.Features.Purchases;

public sealed record PurchaseDto(
    long Id,
    long OwnerId,
    long PumpId,
    long VendorId,
    string VendorName,
    string InvoiceNo,
    DateTime InvoiceDate,
    string? VehicleNo,
    string? DriverName,
    decimal TotalAmount,
    string? Notes,
    DateTime CreatedOn,
    decimal TotalQty,
    string? ProductSummary
);
