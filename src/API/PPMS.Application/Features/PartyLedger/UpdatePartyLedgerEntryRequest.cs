namespace PPMS.Application.Features.PartyLedger;

/// <summary>
/// Khaate ki HAATH SE bani entry ko sudharna (Section AI, sp_PartyLedger_Update).
/// Party nahi badalti — galat party par chadhi ho to entry hatao aur sahi party par nayi daalo.
/// EntryDateTime NULL = tareekh waisi hi. Reason zaroori hai (AuditLog me jaata hai).
/// </summary>
public sealed record UpdatePartyLedgerEntryRequest(
    long PumpId,
    string EntryType,
    decimal Amount,
    DateTime? EntryDateTime,
    string? ReferenceNo,
    string? Notes,
    string? Reason
);
