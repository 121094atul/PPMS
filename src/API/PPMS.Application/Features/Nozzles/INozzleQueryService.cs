namespace PPMS.Application.Features.Nozzles;

public interface INozzleQueryService
{
    Task<IReadOnlyList<NozzleDto>> GetByPumpAsync(long ownerId, long? pumpId, CancellationToken cancellationToken = default);
}
