namespace PPMS.Application.Features.Nozzles;

public sealed class NozzleCommandService(INozzleRepository repository) : INozzleCommandService
{
    public Task<long> SaveAsync(SaveNozzleRequest request, CancellationToken cancellationToken = default)
    {
        return repository.SaveAsync(request, cancellationToken);
    }

    public Task DeleteAsync(long id, long ownerId, CancellationToken cancellationToken = default)
    {
        return repository.DeleteAsync(id, ownerId, cancellationToken);
    }
}
