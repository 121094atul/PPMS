namespace PPMS.Application.Features.Nozzles;

public interface INozzleCommandService
{
    Task<long> SaveAsync(SaveNozzleRequest request, CancellationToken cancellationToken = default);
    Task DeleteAsync(long id, long ownerId, CancellationToken cancellationToken = default);
}
