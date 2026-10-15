namespace PPMS.Application.Features.TankTransactions;

public sealed record SaveTankTransactionRequest(
    long OwnerId,
    long PumpId,
    long TankId,
    string TxnType,
    decimal Quantity,
    string? ReferenceNo,
    string? Notes,
    // Chhoot gayi entry purani tareekh par charhane ke liye. NULL = abhi ka waqt.
    DateTime? TxnDateTime = null
);
