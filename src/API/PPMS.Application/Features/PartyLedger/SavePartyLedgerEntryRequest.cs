namespace PPMS.Application.Features.PartyLedger;

public sealed record SavePartyLedgerEntryRequest(
    long OwnerId,
    long PumpId,
    long PartyId,
    string EntryType,
    decimal Amount,
    string? ReferenceNo,
    string? Notes,
    DateTime? EntryDateTime = null
);
