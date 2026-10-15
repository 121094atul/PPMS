namespace PPMS.Application.Features.Pumps;

public interface IPumpQueryService
{
    Task<IReadOnlyList<PumpDto>> GetByOwnerIdAsync(long ownerId, CancellationToken cancellationToken = default);
}
