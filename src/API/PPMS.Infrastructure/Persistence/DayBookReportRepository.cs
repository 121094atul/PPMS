using Dapper;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;
using PPMS.Application.Features.DayBookReport;

namespace PPMS.Infrastructure.Persistence;

public sealed class DayBookReportRepository(IOptions<DatabaseOptions> options) : IDayBookReportRepository
{
    private readonly DatabaseOptions _options = options.Value;

    public async Task<IReadOnlyList<DayBookEntryDto>> GetAsync(long ownerId, long pumpId, DateOnly dateFrom, DateOnly dateTo, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        var rows = await connection.QueryAsync<DayBookEntryDto>(
            sql: "PUMP.sp_Report_DayBook",
            param: new
            {
                OwnerId = ownerId,
                PumpId = pumpId,
                DateFrom = dateFrom.ToDateTime(TimeOnly.MinValue),
                DateTo = dateTo.ToDateTime(TimeOnly.MinValue)
            },
            commandType: System.Data.CommandType.StoredProcedure);

        return rows.AsList();
    }
}
