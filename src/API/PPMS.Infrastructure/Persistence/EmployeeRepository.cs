using Dapper;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;
using PPMS.Application.Features.Employees;

namespace PPMS.Infrastructure.Persistence;

public sealed class EmployeeRepository(IOptions<DatabaseOptions> options) : IEmployeeRepository
{
    private readonly DatabaseOptions _options = options.Value;

    public async Task<long> SaveAsync(SaveEmployeeRequest request, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        return await connection.ExecuteScalarAsync<long>(
            sql: "PUMP.sp_Employee_Save",
            param: new
            {
                request.Id,
                request.OwnerId,
                request.PumpId,
                request.UserId,
                request.EmployeeCode,
                request.FullName,
                request.Mobile,
                JoinDate = request.JoinDate.ToDateTime(TimeOnly.MinValue),
                request.Designation,
                request.MonthlySalary,
                request.IsActive
            },
            commandType: System.Data.CommandType.StoredProcedure);
    }

    public async Task<IReadOnlyList<EmployeeDto>> GetByPumpAsync(long ownerId, long pumpId, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        var rows = await connection.QueryAsync<EmployeeDto>(
            sql: "PUMP.sp_Employee_List",
            param: new { OwnerId = ownerId, PumpId = pumpId },
            commandType: System.Data.CommandType.StoredProcedure);

        return rows.AsList();
    }

    public async Task DeleteAsync(long id, long ownerId, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        await connection.ExecuteAsync(
            sql: "PUMP.sp_Employee_Delete",
            param: new { Id = id, OwnerId = ownerId },
            commandType: System.Data.CommandType.StoredProcedure);
    }
}
