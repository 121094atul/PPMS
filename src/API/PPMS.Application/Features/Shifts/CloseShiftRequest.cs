namespace PPMS.Application.Features.Shifts;

public sealed record CloseShiftRequest(
    long Id,
    decimal ClosingCash,
    string? Notes,
    IReadOnlyList<ShiftNozzleCloseReadingRequest> NozzleReadings);

public sealed record ShiftNozzleCloseReadingRequest(
    long NozzleId,
    decimal ClosingReading,
    decimal TestingLoss
);
