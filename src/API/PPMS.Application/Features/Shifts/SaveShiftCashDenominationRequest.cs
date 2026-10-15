namespace PPMS.Application.Features.Shifts;

public sealed record SaveShiftCashDenominationRequest(
    long OwnerId,
    long PumpId,
    IReadOnlyList<ShiftCashDenominationLine> Lines
);
