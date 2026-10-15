using Dapper;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;
using PPMS.Application.Features.Staff;

namespace PPMS.Infrastructure.Persistence;

public sealed class StaffRepository(IOptions<DatabaseOptions> options) : IStaffRepository
{
    private readonly DatabaseOptions _options = options.Value;

    public async Task<IReadOnlyList<StaffDto>> GetByPumpAsync(long ownerId, long pumpId, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        var rows = await connection.QueryAsync<StaffDto>(
            sql: "PUMP.sp_Staff_List",
            param: new { OwnerId = ownerId, PumpId = pumpId },
            commandType: System.Data.CommandType.StoredProcedure);

        return rows.AsList();
    }

    public async Task<SaveStaffResult> SaveAsync(SaveStaffRequest request, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        var row = await connection.QuerySingleAsync<SaveStaffResult>(
            sql: "PUMP.sp_Staff_Save",
            param: new
            {
                request.Id,
                request.OwnerId,
                request.PumpId,
                request.EmployeeCode,
                request.FullName,
                request.Mobile,
                JoinDate = request.JoinDate.ToDateTime(TimeOnly.MinValue),
                request.Designation,
                request.MonthlySalary,
                request.IsActive,
                request.WantsLogin,
                request.Username,
                PasswordHash = request.Password,
                request.RoleId
            },
            commandType: System.Data.CommandType.StoredProcedure);

        return row;
    }
}
