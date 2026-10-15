namespace PPMS.Application.Features.Shifts;

public sealed class AttendantCashService(IAttendantCashRepository repository) : IAttendantCashService
{
    public Task SetAttendantAsync(SetAttendantRequest request, long? userId, CancellationToken cancellationToken = default)
    {
        if (request.FloatGiven is < 0)
        {
            throw new InvalidOperationException("Float cannot be negative.");
        }

        return repository.SetAttendantAsync(request, userId, cancellationToken);
    }

    public Task<CollectCashResult> CollectCashAsync(CollectCashRequest request, long? userId, CancellationToken cancellationToken = default)
    {
        if (request.CashReturned < 0)
        {
            throw new InvalidOperationException("Cash cannot be negative.");
        }

        if (request.SlipsAmount is < 0)
        {
            throw new InvalidOperationException("Slip amount cannot be negative.");
        }

        return repository.CollectCashAsync(request, userId, cancellationToken);
    }

    public Task UndoCollectionAsync(long shiftId, long nozzleId, long? userId, CancellationToken cancellationToken = default)
        => repository.UndoCollectionAsync(shiftId, nozzleId, userId, cancellationToken);

    public Task<IReadOnlyList<NozzleCashRow>> GetShiftCashAsync(long shiftId, long ownerId, CancellationToken cancellationToken = default)
        => repository.GetShiftCashAsync(shiftId, ownerId, cancellationToken);

    public Task<IReadOnlyList<PendingCashRow>> GetPendingAsync(long ownerId, long? pumpId, DateOnly? fromDate, DateOnly? toDate, CancellationToken cancellationToken = default)
        => repository.GetPendingAsync(ownerId, pumpId, fromDate, toDate, cancellationToken);

    public Task<IReadOnlyList<AttendantCashRow>> GetAttendantReportAsync(long ownerId, long? pumpId, DateOnly fromDate, DateOnly toDate, CancellationToken cancellationToken = default)
        => repository.GetAttendantReportAsync(ownerId, pumpId, fromDate, toDate, cancellationToken);
}
