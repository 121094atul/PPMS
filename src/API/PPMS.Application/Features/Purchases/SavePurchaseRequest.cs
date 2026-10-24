namespace PPMS.Application.Features.Purchases;

public sealed record SavePurchaseRequest(
    long? Id,
    long OwnerId,
    long PumpId,
    long VendorId,
    string InvoiceNo,
    DateOnly InvoiceDate,
    string? VehicleNo,
    string? DriverName,
    string? Notes,
    List<PurchaseItemRequest> Items,
    // Section AV: tanker jis din utra (tel tank me gaya). Null = bill wala din.
    DateOnly? ReceivedDate = null
);
