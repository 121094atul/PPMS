namespace PPMS.Application.Features.Sales;

public sealed record ReceiptDto(
    long Id,
    long SalesHeaderId,
    string ReceiptNo,
    DateTime ReceiptDateTime,
    string BillNo,
    DateTime BillDateTime,
    string PaymentMode,
    string? VehicleNo,
    string? CustomerName,
    string? AttendantName,
    decimal TotalAmount,
    decimal TotalQuantity,
    decimal BaseAmount,
    decimal TotalCGST,
    decimal TotalSGST,
    string? PumpGSTIN,
    string? PumpAddress
);
