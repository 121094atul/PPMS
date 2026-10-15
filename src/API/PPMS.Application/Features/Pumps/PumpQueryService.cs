namespace PPMS.Application.Features.Pumps;

public sealed class PumpQueryService(IPumpRepository repository) : IPumpQueryService
{
    public Task<IReadOnlyList<PumpDto>> GetByOwnerIdAsync(long ownerId, CancellationToken cancellationToken = default)
    {
        return repository.GetByOwnerIdAsync(ownerId, cancellationToken);
    }
}
