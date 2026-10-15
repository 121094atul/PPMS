namespace PPMS.Application.Features.Shifts;

/// <summary>
/// Pump par har nozzle par alag aadmi hota hai. Shift shuru me use chhutta (float)
/// milta hai, shift ke baad usse cash liya jaata hai. Ye us hisaab ki ek line.
///
/// Field ke naam SP ke column se hubahu milne chahiye - Dapper positional record
/// ko constructor se banata hai.
/// </summary>
public sealed record NozzleCashRow(
    long ShiftId,
    long NozzleId,
    string NozzleCode,
    string ProductName,
    long? EmployeeId,
    string EmployeeName,
    decimal OpeningReading,
    decimal? ClosingReading,
    decimal SoldQty,
    decimal Rate,
    decimal MeterSale,
    decimal FloatGiven,
    decimal SlipsAmount,
    decimal ExpectedCash,
    decimal? CashReturned,
    decimal? ShortExcess,
    DateTime? CashCollectedOn,
    string? CashNotes,
    bool IsCollected
);

/// <summary>Jis nozzle ka cash abhi tak nahi liya - poore din ka cash raat me lene ke liye.</summary>
public sealed record PendingCashRow(
    long ShiftId,
    DateOnly ShiftDate,
    string ShiftCode,
    string Status,
    long NozzleId,
    string NozzleCode,
    string ProductName,
    long? EmployeeId,
    string EmployeeName,
    string? EmployeeMobile,
    decimal MeterSale,
    decimal FloatGiven,
    decimal SlipsAmount,
    decimal ExpectedCash,
    int DaysPending
);

public sealed record AttendantCashRow(
    long? EmployeeId,
    string EmployeeName,
    int Shifts,
    decimal TotalMeterSale,
    decimal TotalFloat,
    decimal TotalSlips,
    decimal TotalExpected,
    decimal TotalReturned,
    decimal TotalShortExcess,
    int PendingCount,
    decimal PendingAmount
);

public sealed record SetAttendantRequest(long ShiftId, long NozzleId, long? EmployeeId, decimal? FloatGiven);

public sealed record CollectCashRequest(long ShiftId, long NozzleId, decimal CashReturned, decimal? SlipsAmount, string? Notes);

public sealed record CollectCashResult(string Result, decimal ExpectedCash, decimal ShortExcess);

public interface IAttendantCashRepository
{
    Task SetAttendantAsync(SetAttendantRequest request, long? userId, CancellationToken cancellationToken = default);
    Task<CollectCashResult> CollectCashAsync(CollectCashRequest request, long? userId, CancellationToken cancellationToken = default);
    Task UndoCollectionAsync(long shiftId, long nozzleId, long? userId, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<NozzleCashRow>> GetShiftCashAsync(long shiftId, long ownerId, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<PendingCashRow>> GetPendingAsync(long ownerId, long? pumpId, DateOnly? fromDate, DateOnly? toDate, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<AttendantCashRow>> GetAttendantReportAsync(long ownerId, long? pumpId, DateOnly fromDate, DateOnly toDate, CancellationToken cancellationToken = default);
}

public interface IAttendantCashService
{
    Task SetAttendantAsync(SetAttendantRequest request, long? userId, CancellationToken cancellationToken = default);
    Task<CollectCashResult> CollectCashAsync(CollectCashRequest request, long? userId, CancellationToken cancellationToken = default);
    Task UndoCollectionAsync(long shiftId, long nozzleId, long? userId, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<NozzleCashRow>> GetShiftCashAsync(long shiftId, long ownerId, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<PendingCashRow>> GetPendingAsync(long ownerId, long? pumpId, DateOnly? fromDate, DateOnly? toDate, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<AttendantCashRow>> GetAttendantReportAsync(long ownerId, long? pumpId, DateOnly fromDate, DateOnly toDate, CancellationToken cancellationToken = default);
}
