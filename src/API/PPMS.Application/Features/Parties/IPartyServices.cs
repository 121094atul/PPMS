using PPMS.Shared.Models;

namespace PPMS.Application.Features.Parties;

public interface IPartyQueryService
{
    Task<PagedResponse<PartyDto>> GetPagedListAsync(long ownerId, long pumpId, string? searchTerm, int pageNumber, int pageSize, CancellationToken cancellationToken = default);
    Task<PartyDto?> GetByIdAsync(long id, long ownerId, long pumpId, CancellationToken cancellationToken = default);
}

public interface IPartyCommandService
{
    Task SaveAsync(SavePartyRequest request, CancellationToken cancellationToken = default);
    Task DeleteAsync(long id, long ownerId, CancellationToken cancellationToken = default);

    // Support console (Section Z)
    Task<int> RecalculateBalancesAsync(long ownerId, long? partyId, CancellationToken cancellationToken = default);
}
