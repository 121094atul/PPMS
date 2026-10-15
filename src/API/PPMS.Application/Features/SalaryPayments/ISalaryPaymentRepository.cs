namespace PPMS.Application.Features.SalaryPayments;

public interface ISalaryPaymentRepository
{
    Task<long> SaveAsync(SaveSalaryPaymentRequest request, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<SalaryPaymentDto>> GetByPumpAsync(long ownerId, long pumpId, int? salaryYear, int? salaryMonth, CancellationToken cancellationToken = default);
}
