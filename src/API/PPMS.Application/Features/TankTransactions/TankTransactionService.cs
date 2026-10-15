namespace PPMS.Application.Features.TankTransactions;

public sealed class TankTransactionService(ITankTransactionRepository repository) : ITankTransactionService
{
    public Task<long> SaveAsync(SaveTankTransactionRequest request, CancellationToken cancellationToken = default)
    {
        PPMS.Application.Common.EntryGuard.PositiveQuantity(request.Quantity, "Quantity");
        PPMS.Application.Common.EntryGuard.NotInFuture(request.TxnDateTime, "Entry date");

        return repository.SaveAsync(request, cancellationToken);
    }

    public Task<IReadOnlyList<TankTransactionDto>> GetByPumpAsync(long ownerId, long pumpId, long? tankId, CancellationToken cancellationToken = default)
    {
        return repository.GetByPumpAsync(ownerId, pumpId, tankId, cancellationToken);
    }
}
