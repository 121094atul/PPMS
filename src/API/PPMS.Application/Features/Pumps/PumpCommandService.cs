namespace PPMS.Application.Features.Pumps;

public sealed class PumpCommandService(IPumpRepository repository) : IPumpCommandService
{
    public Task<long> SaveAsync(SavePumpRequest request, CancellationToken cancellationToken = default)
    {
        return repository.SaveAsync(request, cancellationToken);
    }

    public Task DeleteAsync(long id, long ownerId, CancellationToken cancellationToken = default)
    {
        return repository.DeleteAsync(id, ownerId, cancellationToken);
    }
}
