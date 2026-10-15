using Dapper;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;
using PPMS.Application.Features.SalaryPayments;

namespace PPMS.Infrastructure.Persistence;

public sealed class SalaryPaymentRepository(IOptions<DatabaseOptions> options) : ISalaryPaymentRepository
{
    private readonly DatabaseOptions _options = options.Value;

    public async Task<long> SaveAsync(SaveSalaryPaymentRequest request, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        return await connection.ExecuteScalarAsync<long>(
            sql: "PUMP.sp_SalaryPayment_Save",
            param: new
            {
                request.Id,
                request.OwnerId,
                request.PumpId,
                request.EmployeeId,
                request.SalaryYear,
                request.SalaryMonth,
                request.Amount,
                PaidOn = request.PaidOn.ToDateTime(TimeOnly.MinValue),
                request.PaymentMode,
                request.ReferenceNo,
                request.Notes
            },
            commandType: System.Data.CommandType.StoredProcedure);
    }

    public async Task<IReadOnlyList<SalaryPaymentDto>> GetByPumpAsync(long ownerId, long pumpId, int? salaryYear, int? salaryMonth, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        var rows = await connection.QueryAsync<SalaryPaymentDto>(
            sql: "PUMP.sp_SalaryPayment_List",
            param: new { OwnerId = ownerId, PumpId = pumpId, SalaryYear = salaryYear, SalaryMonth = salaryMonth },
            commandType: System.Data.CommandType.StoredProcedure);

        return rows.AsList();
    }
}
