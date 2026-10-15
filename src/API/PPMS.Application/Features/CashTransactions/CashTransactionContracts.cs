namespace PPMS.Application.Features.CashTransactions;

public sealed record CashTransactionDto(
    long Id,
    long OwnerId,
    long PumpId,
    long? ShiftId,
    string TxnType,
    decimal Amount,
    string? ReferenceNo,
    string? Narration,
    DateTime TxnDateTime
);

public sealed record SaveCashTransactionRequest(
    long OwnerId,
    long PumpId,
    long? ShiftId,
    string TxnType,
    decimal Amount,
    string? ReferenceNo,
    string? Narration,
    DateTime? TxnDateTime
);

public interface ICashTransactionRepository
{
    Task<long> SaveAsync(SaveCashTransactionRequest request, CancellationToken cancellationToken = default);
    Task<PPMS.Shared.Models.PagedResponse<CashTransactionDto>> GetPagedListAsync(long ownerId, long pumpId, DateTime? fromDate, DateTime? toDate, string? searchTerm, int pageNumber, int pageSize, CancellationToken cancellationToken = default);
    Task DeleteAsync(long id, long ownerId, CancellationToken cancellationToken = default);
}

public interface ICashTransactionService
{
    Task<long> SaveAsync(SaveCashTransactionRequest request, CancellationToken cancellationToken = default);
    Task<PPMS.Shared.Models.PagedResponse<CashTransactionDto>> GetPagedListAsync(long ownerId, long pumpId, DateTime? fromDate, DateTime? toDate, string? searchTerm, int pageNumber, int pageSize, CancellationToken cancellationToken = default);
    Task DeleteAsync(long id, long ownerId, CancellationToken cancellationToken = default);
}

public sealed class CashTransactionService(ICashTransactionRepository repository, PPMS.Application.Interfaces.IWhatsAppNotificationService whatsappService) : ICashTransactionService
{
    public async Task<long> SaveAsync(SaveCashTransactionRequest request, CancellationToken cancellationToken = default)
    {
        PPMS.Application.Common.EntryGuard.PositiveQuantity(request.Amount, "Amount");
        PPMS.Application.Common.EntryGuard.NotInFuture(request.TxnDateTime, "Entry date");

        var id = await repository.SaveAsync(request, cancellationToken);
        if (id > 0 && request.TxnType == "BANK_DEPOSIT")
        {
            var msg = $"🏦 *Bank Deposit Alert*\n\n" +
                      $"Amount: {request.Amount:C}\n" +
                      $"Ref: {request.ReferenceNo}\n" +
                      $"Notes: {request.Narration}";
            _ = Task.Run(() => whatsappService.SendToOwnerAsync(request.OwnerId, "BANK_DEPOSIT", msg, CancellationToken.None));
        }
        return id;
    }

    public Task<PPMS.Shared.Models.PagedResponse<CashTransactionDto>> GetPagedListAsync(long ownerId, long pumpId, DateTime? fromDate, DateTime? toDate, string? searchTerm, int pageNumber, int pageSize, CancellationToken cancellationToken = default)
        => repository.GetPagedListAsync(ownerId, pumpId, fromDate, toDate, searchTerm, pageNumber, pageSize, cancellationToken);

    public Task DeleteAsync(long id, long ownerId, CancellationToken cancellationToken = default)
        => repository.DeleteAsync(id, ownerId, cancellationToken);
}
