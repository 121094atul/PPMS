namespace PPMS.Application.Features.Expenses;

public sealed record ExpenseDto(
    long Id,
    long OwnerId,
    long PumpId,
    long? ShiftId,
    long ExpenseHeadId,
    string ExpenseHeadName,
    decimal Amount,
    string PaymentMode,
    string? ReferenceNo,
    string? Narration,
    DateTime TxnDateTime
);

public sealed record SaveExpenseRequest(
    long OwnerId,
    long PumpId,
    long? ShiftId,
    long ExpenseHeadId,
    decimal Amount,
    string PaymentMode,
    string? ReferenceNo,
    string? Narration,
    DateTime? TxnDateTime
);

public interface IExpenseRepository
{
    Task<long> SaveAsync(SaveExpenseRequest request, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<ExpenseDto>> GetByPumpAsync(long ownerId, long pumpId, CancellationToken cancellationToken = default);
    Task<PPMS.Shared.Models.PagedResponse<ExpenseDto>> GetPagedByPumpAsync(long ownerId, long pumpId, DateTime? fromDate, DateTime? toDate, string? searchTerm, int pageNumber, int pageSize, CancellationToken cancellationToken = default);
    Task DeleteAsync(long id, long ownerId, CancellationToken cancellationToken = default);
}

public interface IExpenseService
{
    Task<long> SaveAsync(SaveExpenseRequest request, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<ExpenseDto>> GetByPumpAsync(long ownerId, long pumpId, CancellationToken cancellationToken = default);
    Task<PPMS.Shared.Models.PagedResponse<ExpenseDto>> GetPagedByPumpAsync(long ownerId, long pumpId, DateTime? fromDate, DateTime? toDate, string? searchTerm, int pageNumber, int pageSize, CancellationToken cancellationToken = default);
    Task DeleteAsync(long id, long ownerId, CancellationToken cancellationToken = default);
}

public sealed class ExpenseService(IExpenseRepository repository, PPMS.Application.Interfaces.IWhatsAppNotificationService whatsappService) : IExpenseService
{
    public async Task<long> SaveAsync(SaveExpenseRequest request, CancellationToken cancellationToken = default)
    {
        PPMS.Application.Common.EntryGuard.PositiveQuantity(request.Amount, "Amount");
        PPMS.Application.Common.EntryGuard.NotInFuture(request.TxnDateTime, "Expense date");

        var id = await repository.SaveAsync(request, cancellationToken);
        if (id > 0 && request.Amount > 5000)
        {
            var msg = $"💸 *Large Expense Alert*\n\n" +
                      $"Amount: {request.Amount:C}\n" +
                      $"Mode: {request.PaymentMode}\n" +
                      $"Ref: {request.ReferenceNo}\n" +
                      $"Notes: {request.Narration}";
            _ = Task.Run(() => whatsappService.SendToOwnerAsync(request.OwnerId, "BIG_EXPENSE", msg, CancellationToken.None));
        }
        return id;
    }

    public Task<IReadOnlyList<ExpenseDto>> GetByPumpAsync(long ownerId, long pumpId, CancellationToken cancellationToken = default)
        => repository.GetByPumpAsync(ownerId, pumpId, cancellationToken);

    public Task<PPMS.Shared.Models.PagedResponse<ExpenseDto>> GetPagedByPumpAsync(long ownerId, long pumpId, DateTime? fromDate, DateTime? toDate, string? searchTerm, int pageNumber, int pageSize, CancellationToken cancellationToken = default)
        => repository.GetPagedByPumpAsync(ownerId, pumpId, fromDate, toDate, searchTerm, pageNumber, pageSize, cancellationToken);

    public Task DeleteAsync(long id, long ownerId, CancellationToken cancellationToken = default)
        => repository.DeleteAsync(id, ownerId, cancellationToken);
}
