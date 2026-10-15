namespace PPMS.Application.Features.Nozzles;

public sealed class NozzleQueryService(INozzleRepository repository) : INozzleQueryService
{
    public Task<IReadOnlyList<NozzleDto>> GetByPumpAsync(long ownerId, long? pumpId, CancellationToken cancellationToken = default)
    {
        return repository.GetByPumpAsync(ownerId, pumpId, cancellationToken);
    }
}
