namespace PPMS.Application.Features.Pumps;

public interface IPumpRepository
{
    Task<IReadOnlyList<PumpDto>> GetByOwnerIdAsync(long ownerId, CancellationToken cancellationToken = default);
    Task<long> SaveAsync(SavePumpRequest request, CancellationToken cancellationToken = default);
    Task DeleteAsync(long id, long ownerId, CancellationToken cancellationToken = default);
}
