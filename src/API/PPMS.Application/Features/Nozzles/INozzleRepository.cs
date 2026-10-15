namespace PPMS.Application.Features.Nozzles;

public interface INozzleRepository
{
    Task<IReadOnlyList<NozzleDto>> GetByPumpAsync(long ownerId, long? pumpId, CancellationToken cancellationToken = default);
    Task<long> SaveAsync(SaveNozzleRequest request, CancellationToken cancellationToken = default);
    Task DeleteAsync(long id, long ownerId, CancellationToken cancellationToken = default);
}
