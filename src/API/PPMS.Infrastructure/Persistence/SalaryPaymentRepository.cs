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

    public async Task SetAdvanceCutAsync(long ownerId, long pumpId, long salaryPaymentId, decimal amount, long? userId, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        await connection.ExecuteAsync(
            sql: "PUMP.sp_SalaryPayment_SetAdvanceCut",
            param: new { OwnerId = ownerId, PumpId = pumpId, SalaryPaymentId = salaryPaymentId, Amount = amount, UserId = userId },
            commandType: System.Data.CommandType.StoredProcedure);
    }

    public async Task<long> SaveAdvanceAsync(SaveEmployeeAdvanceRequest request, long ownerId, long? userId, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        return await connection.ExecuteScalarAsync<long>(
            sql: "PUMP.sp_EmployeeAdvance_Save",
            param: new
            {
                OwnerId = ownerId,
                request.PumpId,
                request.EmployeeId,
                request.EntryType,
                request.Amount,
                EntryDate = request.EntryDate.ToDateTime(TimeOnly.MinValue),
                request.PaymentMode,
                request.Notes,
                UserId = userId,
                request.ShiftId
            },
            commandType: System.Data.CommandType.StoredProcedure);
    }

    public async Task DeleteAdvanceAsync(long id, long ownerId, long? userId, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        await connection.ExecuteAsync(
            sql: "PUMP.sp_EmployeeAdvance_Delete",
            param: new { Id = id, OwnerId = ownerId, UserId = userId },
            commandType: System.Data.CommandType.StoredProcedure);
    }

    public async Task<IReadOnlyList<EmployeeAdvanceDto>> GetAdvancesAsync(long ownerId, long pumpId, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        var rows = await connection.QueryAsync<EmployeeAdvanceDto>(
            sql: "PUMP.sp_EmployeeAdvance_List",
            param: new { OwnerId = ownerId, PumpId = pumpId, Top = 50 },
            commandType: System.Data.CommandType.StoredProcedure);
        return rows.AsList();
    }

    public async Task<IReadOnlyList<SalarySummaryDto>> GetSummaryAsync(long ownerId, long pumpId, int year, int month, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        var rows = await connection.QueryAsync<SalarySummaryDto>(
            sql: "PUMP.sp_Salary_Summary",
            param: new { OwnerId = ownerId, PumpId = pumpId, Year = year, Month = month },
            commandType: System.Data.CommandType.StoredProcedure);
        return rows.AsList();
    }
}
