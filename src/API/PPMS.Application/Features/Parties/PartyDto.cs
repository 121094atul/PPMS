namespace PPMS.Application.Features.Parties;

public sealed record PartyDto(
    long Id,
    long PumpId,
    string PartyName,
    string PartyType,
    string Address,
    string Mobile,
    string Email,
    string GSTIN,
    decimal CreditLimit,
    decimal CurrentBalance,
    bool IsActive
);
