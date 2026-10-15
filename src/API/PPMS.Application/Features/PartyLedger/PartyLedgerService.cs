namespace PPMS.Application.Features.PartyLedger;

public sealed class PartyLedgerService(
    IPartyLedgerRepository repository,
    PPMS.Application.Features.Parties.IPartyReadRepository partyRepository,
    PPMS.Application.Interfaces.IWhatsAppNotificationService notificationService) : IPartyLedgerService
{
    public async Task<long> SaveAsync(SavePartyLedgerEntryRequest request, CancellationToken cancellationToken = default)
    {
        var id = await repository.SaveAsync(request, cancellationToken);
        
        try
        {
            var party = await partyRepository.GetByIdAsync(request.PartyId, request.OwnerId, request.PumpId, cancellationToken);
            if (party != null)
            {
                var msg = $"Dear {party.PartyName},\nA {request.EntryType} of Rs.{request.Amount} has been added to your ledger on {DateTime.Today:dd-MMM-yyyy}.";
                if (!string.IsNullOrWhiteSpace(request.ReferenceNo)) msg += $"\nRef: {request.ReferenceNo}";
                msg += "\n- PUMP Management";

                if (!string.IsNullOrWhiteSpace(party.Mobile))
                {
                    await notificationService.SendMessageAsync(party.Mobile, msg, cancellationToken);
                }

                var ownerMsg = $"Party Ledger Update:\nParty: {party.PartyName}\nType: {request.EntryType}\nAmount: Rs.{request.Amount}";
                await notificationService.SendToOwnerAsync(request.OwnerId, "PARTY_LEDGER", ownerMsg, cancellationToken);
            }
        }
        catch
        {
            // Silently ignore notification failures
        }

        return id;
    }

    public Task<IReadOnlyList<PartyLedgerEntryDto>> GetByPumpAsync(long ownerId, long pumpId, long? partyId, CancellationToken cancellationToken = default)
    {
        return repository.GetByPumpAsync(ownerId, pumpId, partyId, cancellationToken);
    }

    public async Task<PPMS.Shared.Models.PagedResponse<PartyLedgerEntryDto>> GetPagedListAsync(long ownerId, long pumpId, long? partyId, string? searchTerm, int pageNumber, int pageSize, CancellationToken cancellationToken = default)
    {
        var (items, totalCount) = await repository.GetPagedListAsync(ownerId, pumpId, partyId, searchTerm, pageNumber, pageSize, cancellationToken);
        return new PPMS.Shared.Models.PagedResponse<PartyLedgerEntryDto>(items, totalCount, pageNumber, pageSize);
    }

    public Task<PartyStatementDto> GetStatementAsync(long ownerId, long pumpId, long partyId, string? searchTerm, int pageNumber, int pageSize, CancellationToken cancellationToken = default)
    {
        return repository.GetStatementAsync(ownerId, pumpId, partyId, searchTerm, pageNumber, pageSize, cancellationToken);
    }

    // Badalne / hatane par WhatsApp nahi bhejte — party ko "aapka khaata badla" ka sandesh
    // bina sandarbh ke ulta ghabra deta. Kisne / kyun, AuditLog me hai.
    public Task UpdateAsync(long id, long ownerId, long? userId, UpdatePartyLedgerEntryRequest request, CancellationToken cancellationToken = default)
        => repository.UpdateAsync(id, ownerId, userId, request, cancellationToken);

    public Task DeleteAsync(long id, long ownerId, long pumpId, long? userId, string? reason, CancellationToken cancellationToken = default)
        => repository.DeleteAsync(id, ownerId, pumpId, userId, reason, cancellationToken);
}
