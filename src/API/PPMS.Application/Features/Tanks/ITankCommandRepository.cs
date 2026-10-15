namespace PPMS.Application.Features.Tanks;

public interface ITankCommandRepository
{
    Task SaveAsync(SaveTankRequest request, CancellationToken cancellationToken = default);
    Task DeleteAsync(long id, long ownerId, CancellationToken cancellationToken = default);
}
