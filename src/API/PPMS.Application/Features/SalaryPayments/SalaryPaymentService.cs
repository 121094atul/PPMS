namespace PPMS.Application.Features.SalaryPayments;

public sealed class SalaryPaymentService(ISalaryPaymentRepository repository) : ISalaryPaymentService
{
    public Task<long> SaveAsync(SaveSalaryPaymentRequest request, CancellationToken cancellationToken = default)
        => repository.SaveAsync(request, cancellationToken);

    public Task<IReadOnlyList<SalaryPaymentDto>> GetByPumpAsync(long ownerId, long pumpId, int? salaryYear, int? salaryMonth, CancellationToken cancellationToken = default)
        => repository.GetByPumpAsync(ownerId, pumpId, salaryYear, salaryMonth, cancellationToken);
}
