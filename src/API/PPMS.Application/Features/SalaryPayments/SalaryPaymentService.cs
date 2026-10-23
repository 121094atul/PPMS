namespace PPMS.Application.Features.SalaryPayments;

public sealed class SalaryPaymentService(ISalaryPaymentRepository repository) : ISalaryPaymentService
{
    /// <summary>
    /// Salary save; AdvanceCut diya ho to us payment ka "advance se kata" bhi (Section AQ). null aaye to
    /// advance ko haath nahi lagate - purana client wahi rehta hai.
    /// </summary>
    public async Task<long> SaveAsync(SaveSalaryPaymentRequest request, CancellationToken cancellationToken = default)
    {
        var id = await repository.SaveAsync(request, cancellationToken);
        if (request.AdvanceCut is decimal cut && id > 0)
        {
            await repository.SetAdvanceCutAsync(request.OwnerId, request.PumpId, id, cut, null, cancellationToken);
        }
        return id;
    }

    public Task<IReadOnlyList<SalaryPaymentDto>> GetByPumpAsync(long ownerId, long pumpId, int? salaryYear, int? salaryMonth, CancellationToken cancellationToken = default)
        => repository.GetByPumpAsync(ownerId, pumpId, salaryYear, salaryMonth, cancellationToken);

    public Task<long> SaveAdvanceAsync(SaveEmployeeAdvanceRequest request, long ownerId, long? userId, CancellationToken cancellationToken = default)
        => repository.SaveAdvanceAsync(request, ownerId, userId, cancellationToken);

    public Task DeleteAdvanceAsync(long id, long ownerId, long? userId, CancellationToken cancellationToken = default)
        => repository.DeleteAdvanceAsync(id, ownerId, userId, cancellationToken);

    public Task<IReadOnlyList<EmployeeAdvanceDto>> GetAdvancesAsync(long ownerId, long pumpId, CancellationToken cancellationToken = default)
        => repository.GetAdvancesAsync(ownerId, pumpId, cancellationToken);

    public Task<IReadOnlyList<SalarySummaryDto>> GetSummaryAsync(long ownerId, long pumpId, int year, int month, CancellationToken cancellationToken = default)
        => repository.GetSummaryAsync(ownerId, pumpId, year, month, cancellationToken);
}
