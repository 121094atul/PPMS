namespace PPMS.Application.Features.ExpenseHeads;

public sealed record ExpenseHeadDto(long Id, long OwnerId, long PumpId, string HeadName, bool IsActive);
public sealed record SaveExpenseHeadRequest(long? Id, long OwnerId, long PumpId, string HeadName, bool IsActive);

public interface IExpenseHeadRepository
{
    Task<long> SaveAsync(SaveExpenseHeadRequest request, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<ExpenseHeadDto>> GetByPumpAsync(long ownerId, long pumpId, CancellationToken cancellationToken = default);
    Task DeleteAsync(long id, long ownerId, CancellationToken cancellationToken = default);
}

public interface IExpenseHeadService
{
    Task<long> SaveAsync(SaveExpenseHeadRequest request, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<ExpenseHeadDto>> GetByPumpAsync(long ownerId, long pumpId, CancellationToken cancellationToken = default);
    Task DeleteAsync(long id, long ownerId, CancellationToken cancellationToken = default);
}

public sealed class ExpenseHeadService(IExpenseHeadRepository repository) : IExpenseHeadService
{
    public Task<long> SaveAsync(SaveExpenseHeadRequest request, CancellationToken cancellationToken = default)
        => repository.SaveAsync(request, cancellationToken);

    public Task<IReadOnlyList<ExpenseHeadDto>> GetByPumpAsync(long ownerId, long pumpId, CancellationToken cancellationToken = default)
        => repository.GetByPumpAsync(ownerId, pumpId, cancellationToken);

    public Task DeleteAsync(long id, long ownerId, CancellationToken cancellationToken = default)
        => repository.DeleteAsync(id, ownerId, cancellationToken);
}
