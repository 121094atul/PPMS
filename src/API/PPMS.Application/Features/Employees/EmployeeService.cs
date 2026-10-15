namespace PPMS.Application.Features.Employees;

public sealed class EmployeeService(IEmployeeRepository repository) : IEmployeeService
{
    public Task<long> SaveAsync(SaveEmployeeRequest request, CancellationToken cancellationToken = default)
        => repository.SaveAsync(request, cancellationToken);

    public Task<IReadOnlyList<EmployeeDto>> GetByPumpAsync(long ownerId, long pumpId, CancellationToken cancellationToken = default)
        => repository.GetByPumpAsync(ownerId, pumpId, cancellationToken);

    public Task DeleteAsync(long id, long ownerId, CancellationToken cancellationToken = default)
        => repository.DeleteAsync(id, ownerId, cancellationToken);
}
