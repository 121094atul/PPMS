namespace PPMS.Application.Features.TankTransactions;

public interface ITankTransactionRepository
{
    Task<long> SaveAsync(SaveTankTransactionRequest request, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<TankTransactionDto>> GetByPumpAsync(long ownerId, long pumpId, long? tankId, CancellationToken cancellationToken = default);
}
