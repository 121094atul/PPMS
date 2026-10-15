using PPMS.Shared.Models;

namespace PPMS.Application.Features.Parties;

public sealed class PartyQueryService(IPartyReadRepository repository) : IPartyQueryService
{
    public Task<PagedResponse<PartyDto>> GetPagedListAsync(long ownerId, long pumpId, string? searchTerm, int pageNumber, int pageSize, CancellationToken cancellationToken = default)
    {
        return repository.GetPagedListAsync(ownerId, pumpId, searchTerm, pageNumber, pageSize, cancellationToken);
    }
    
    public Task<PartyDto?> GetByIdAsync(long id, long ownerId, long pumpId, CancellationToken cancellationToken = default)
    {
        return repository.GetByIdAsync(id, ownerId, pumpId, cancellationToken);
    }
}

public sealed class PartyCommandService(IPartyCommandRepository repository) : IPartyCommandService
{
    public Task SaveAsync(SavePartyRequest request, CancellationToken cancellationToken = default)
    {
        return repository.SaveAsync(request, cancellationToken);
    }

    public Task DeleteAsync(long id, long ownerId, CancellationToken cancellationToken = default)
    {
        return repository.DeleteAsync(id, ownerId, cancellationToken);
    }

    public Task<int> RecalculateBalancesAsync(long ownerId, long? partyId, CancellationToken cancellationToken = default)
        => repository.RecalculateBalancesAsync(ownerId, partyId, cancellationToken);
}
