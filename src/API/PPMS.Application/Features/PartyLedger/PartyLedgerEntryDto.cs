namespace PPMS.Application.Features.PartyLedger;

public sealed record PartyLedgerEntryDto(
    long Id,
    long OwnerId,
    long PumpId,
    long PartyId,
    string PartyName,
    string EntryType,
    decimal Amount,
    DateTime EntryDateTime,
    string? ReferenceNo,
    string? Notes
);
