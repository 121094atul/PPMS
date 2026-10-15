using System.Data;
using Dapper;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;
using PPMS.Application.Features.Shifts;

namespace PPMS.Infrastructure.Persistence;

public sealed class AttendantCashRepository(IOptions<DatabaseOptions> options) : IAttendantCashRepository
{
    private readonly DatabaseOptions _options = options.Value;

    public async Task SetAttendantAsync(SetAttendantRequest request, long? userId, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        await connection.ExecuteAsync(
            sql: "PUMP.sp_ShiftNozzle_SetAttendant",
            param: new { request.ShiftId, request.NozzleId, request.EmployeeId, request.FloatGiven, UserId = userId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<CollectCashResult> CollectCashAsync(CollectCashRequest request, long? userId, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        return await connection.QuerySingleAsync<CollectCashResult>(
            sql: "PUMP.sp_ShiftNozzle_CollectCash",
            param: new { request.ShiftId, request.NozzleId, request.CashReturned, request.SlipsAmount, request.Notes, UserId = userId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task UndoCollectionAsync(long shiftId, long nozzleId, long? userId, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        await connection.ExecuteAsync(
            sql: "PUMP.sp_ShiftNozzle_UndoCollection",
            param: new { ShiftId = shiftId, NozzleId = nozzleId, UserId = userId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<IReadOnlyList<NozzleCashRow>> GetShiftCashAsync(long shiftId, long ownerId, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        var rows = await connection.QueryAsync<NozzleCashRow>(
            sql: "PUMP.sp_ShiftNozzle_CashSummary",
            // Endpoint par ITenantGuard pehle se hai; ye SP ka apna doosra taala hai
            // taaki SP kabhi caller ke bharose na rahe (Section M).
            param: new { ShiftId = shiftId, OwnerId = ownerId },
            commandType: CommandType.StoredProcedure);

        return rows.AsList();
    }

    public async Task<IReadOnlyList<PendingCashRow>> GetPendingAsync(long ownerId, long? pumpId, DateOnly? fromDate, DateOnly? toDate, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        var rows = await connection.QueryAsync<PendingCashRow>(
            sql: "PUMP.sp_ShiftNozzle_PendingCash",
            param: new { OwnerId = ownerId, PumpId = pumpId, FromDate = fromDate, ToDate = toDate },
            commandType: CommandType.StoredProcedure);

        return rows.AsList();
    }

    public async Task<IReadOnlyList<AttendantCashRow>> GetAttendantReportAsync(long ownerId, long? pumpId, DateOnly fromDate, DateOnly toDate, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        var rows = await connection.QueryAsync<AttendantCashRow>(
            sql: "PUMP.sp_Report_AttendantCash",
            param: new { OwnerId = ownerId, PumpId = pumpId, FromDate = fromDate, ToDate = toDate },
            commandType: CommandType.StoredProcedure);

        return rows.AsList();
    }
}
