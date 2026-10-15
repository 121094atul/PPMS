namespace PPMS.Application.Features.Tanks;

public sealed class TankCommandService(ITankCommandRepository repository) : ITankCommandService
{
    public Task SaveAsync(SaveTankRequest request, CancellationToken cancellationToken = default)
    {
        return repository.SaveAsync(request, cancellationToken);
    }

    public Task DeleteAsync(long id, long ownerId, CancellationToken cancellationToken = default)
    {
        return repository.DeleteAsync(id, ownerId, cancellationToken);
    }
}
