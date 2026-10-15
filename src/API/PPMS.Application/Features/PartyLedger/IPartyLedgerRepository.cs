namespace PPMS.Application.Features.PartyLedger;

public interface IPartyLedgerRepository
{
    Task<long> SaveAsync(SavePartyLedgerEntryRequest request, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<PartyLedgerEntryDto>> GetByPumpAsync(long ownerId, long pumpId, long? partyId, CancellationToken cancellationToken = default);
    Task<(IReadOnlyList<PartyLedgerEntryDto> Items, int TotalCount)> GetPagedListAsync(long ownerId, long pumpId, long? partyId, string? searchTerm, int pageNumber, int pageSize, CancellationToken cancellationToken = default);
    Task<PartyStatementDto> GetStatementAsync(long ownerId, long pumpId, long partyId, string? searchTerm, int pageNumber, int pageSize, CancellationToken cancellationToken = default);
    Task UpdateAsync(long id, long ownerId, long? userId, UpdatePartyLedgerEntryRequest request, CancellationToken cancellationToken = default);
    Task DeleteAsync(long id, long ownerId, long pumpId, long? userId, string? reason, CancellationToken cancellationToken = default);
}
