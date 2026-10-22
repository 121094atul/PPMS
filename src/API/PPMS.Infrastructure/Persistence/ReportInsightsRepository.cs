using Dapper;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;
using PPMS.Application.Features.ReportInsights;

namespace PPMS.Infrastructure.Persistence;

public sealed class ReportInsightsRepository(IOptions<DatabaseOptions> options) : IReportInsightsRepository
{
    private readonly DatabaseOptions _options = options.Value;

    public async Task<IReadOnlyList<OutstandingPartyDto>> GetOutstandingAsync(long ownerId, long pumpId, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        var rows = await connection.QueryAsync<OutstandingPartyDto>(
            sql: "PUMP.sp_Report_Outstanding",
            param: new { OwnerId = ownerId, PumpId = pumpId },
            commandType: System.Data.CommandType.StoredProcedure);

        return rows.AsList();
    }

    public async Task<IReadOnlyList<PumpComparisonDto>> GetPumpComparisonAsync(long ownerId, DateOnly dateFrom, DateOnly dateTo, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        var rows = await connection.QueryAsync<PumpComparisonDto>(
            sql: "PUMP.sp_Report_PumpComparison",
            param: new
            {
                OwnerId = ownerId,
                DateFrom = dateFrom.ToDateTime(TimeOnly.MinValue),
                DateTo = dateTo.ToDateTime(TimeOnly.MinValue)
            },
            commandType: System.Data.CommandType.StoredProcedure);

        return rows.AsList();
    }

    public async Task<IReadOnlyList<DailyStockRegisterDto>> GetDailyStockRegisterAsync(long pumpId, long productId, int month, int year, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        var rows = await connection.QueryAsync<DailyStockRegisterDto>(
            sql: "PUMP.sp_Report_DailyStockRegister",
            param: new
            {
                PumpId = pumpId,
                ProductId = productId,
                Month = month,
                Year = year
            },
            commandType: System.Data.CommandType.StoredProcedure);

        return rows.AsList();
    }

    public async Task<IReadOnlyList<MonthlySaleRegisterDto>> GetMonthlySaleRegisterAsync(long pumpId, long productId, int month, int year, long ownerId, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        var rows = await connection.QueryAsync<MonthlySaleRegisterDto>(
            sql: "PUMP.sp_Report_MonthlySaleRegister",
            param: new
            {
                PumpId = pumpId,
                ProductId = productId,
                Month = month,
                Year = year,
                OwnerId = ownerId
            },
            commandType: System.Data.CommandType.StoredProcedure);

        return rows.AsList();
    }

    public async Task<IReadOnlyList<ProfitLossLineDto>> GetProfitLossAsync(long ownerId, long pumpId, DateOnly dateFrom, DateOnly dateTo, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        var rows = await connection.QueryAsync<ProfitLossLineDto>(
            sql: "PUMP.sp_Report_ProfitLoss",
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

    public async Task<IReadOnlyList<FinancialLineDto>> GetFinancialsAsync(long ownerId, long pumpId, DateOnly dateFrom, DateOnly dateTo, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        var rows = await connection.QueryAsync<FinancialLineDto>(
            sql: "PUMP.sp_Report_Financials",
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

    public async Task<IReadOnlyList<AuditLogEntryDto>> GetActivityLogAsync(long ownerId, DateOnly dateFrom, DateOnly dateTo, string? area, int pageNumber, int pageSize, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        var rows = await connection.QueryAsync<AuditLogEntryDto>(
            sql: "PUMP.sp_AuditLog_List",
            param: new
            {
                OwnerId = ownerId,
                DateFrom = dateFrom.ToDateTime(TimeOnly.MinValue),
                DateTo = dateTo.ToDateTime(TimeOnly.MinValue),
                Area = string.IsNullOrWhiteSpace(area) ? null : area,
                PageNumber = pageNumber,
                PageSize = pageSize
            },
            commandType: System.Data.CommandType.StoredProcedure);

        return rows.AsList();
    }
}
