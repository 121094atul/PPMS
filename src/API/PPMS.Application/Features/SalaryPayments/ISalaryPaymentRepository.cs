namespace PPMS.Application.Features.SalaryPayments;

public interface ISalaryPaymentRepository
{
    Task<long> SaveAsync(SaveSalaryPaymentRequest request, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<SalaryPaymentDto>> GetByPumpAsync(long ownerId, long pumpId, int? salaryYear, int? salaryMonth, CancellationToken cancellationToken = default);

    // Section AQ - advance aur mahine ka hisaab.
    Task SetAdvanceCutAsync(long ownerId, long pumpId, long salaryPaymentId, decimal amount, long? userId, CancellationToken cancellationToken = default);
    Task<long> SaveAdvanceAsync(SaveEmployeeAdvanceRequest request, long ownerId, long? userId, CancellationToken cancellationToken = default);
    Task DeleteAdvanceAsync(long id, long ownerId, long? userId, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<EmployeeAdvanceDto>> GetAdvancesAsync(long ownerId, long pumpId, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<SalarySummaryDto>> GetSummaryAsync(long ownerId, long pumpId, int year, int month, CancellationToken cancellationToken = default);
}
