namespace PPMS.Application.Features.Employees;

public interface IEmployeeService
{
    Task<long> SaveAsync(SaveEmployeeRequest request, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<EmployeeDto>> GetByPumpAsync(long ownerId, long pumpId, CancellationToken cancellationToken = default);
    Task DeleteAsync(long id, long ownerId, CancellationToken cancellationToken = default);
}
