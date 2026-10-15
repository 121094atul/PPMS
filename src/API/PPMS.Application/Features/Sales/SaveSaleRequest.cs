namespace PPMS.Application.Features.Sales;

public sealed record SaveSaleRequest(
    long OwnerId,
    long PumpId,
    long ShiftId,
    string PaymentMode,
    long? PartyId,
    string? VehicleNo,
    string? CustomerName,
    string? AttendantName,
    List<SaleItemRequest> Items,
    /// <summary>
    /// Bill ki tareekh. NULL bhejein to abhi ka waqt lag jaata hai.
    /// Ye isliye hai ki agar pump wale kuch din ki entry karna bhool jayen to wo
    /// purani tareekh daal kar hisaab poora kar sakein.
    /// </summary>
    DateTime? BillDateTime = null
);
