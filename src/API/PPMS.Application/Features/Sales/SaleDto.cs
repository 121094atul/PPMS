namespace PPMS.Application.Features.Sales;

public sealed record SaleDto(
    long Id,
    long OwnerId,
    long PumpId,
    long ShiftId,
    long? PartyId,
    string BillNo,
    DateTime BillDateTime,
    string PaymentMode,
    string? VehicleNo,
    string? CustomerName,
    string? AttendantName,
    decimal TotalAmount,
    // Void kiya hua bill mitta nahi — list me nishaan ke saath dikhta hai,
    // lekin kisi total/report me nahi ginta.
    bool IsVoid,
    DateTime? VoidedOn,
    string? VoidReason
);
