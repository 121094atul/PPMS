namespace PPMS.Application.Features.Pumps;

public interface IPumpCommandService
{
    Task<long> SaveAsync(SavePumpRequest request, CancellationToken cancellationToken = default);
    Task DeleteAsync(long id, long ownerId, CancellationToken cancellationToken = default);
}
