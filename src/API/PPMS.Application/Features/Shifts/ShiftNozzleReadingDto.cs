namespace PPMS.Application.Features.Shifts;

public sealed record ShiftNozzleReadingDto(
    long NozzleId,
    string NozzleCode,
    string ProductName,
    decimal OpeningReading,
    decimal? ClosingReading,
    decimal TestingLoss,
    decimal Rate,
    decimal SoldQty,
    decimal SoldAmount
);
