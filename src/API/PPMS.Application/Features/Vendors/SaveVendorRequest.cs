namespace PPMS.Application.Features.Vendors;

public sealed record SaveVendorRequest(
    long? Id,
    long OwnerId,
    long PumpId,
    string VendorName,
    string? ContactNo,
    string? GSTIN,
    string? Address,
    bool IsActive
);
