namespace PPMS.Application.Features.TankTransactions;

public sealed record TankTransactionDto(
    long Id,
    long OwnerId,
    long PumpId,
    long TankId,
    string TankName,
    string TxnType,
    decimal Quantity,
    DateTime TxnDateTime,
    string? ReferenceNo,
    string? Notes
);
