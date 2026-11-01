using Dapper;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;
using PPMS.Application.Interfaces;

namespace PPMS.Infrastructure.Persistence;

/// <summary>Plan ka rate - AppSettings (Section BB).</summary>
public sealed class PlanPriceRepository(IOptions<DatabaseOptions> options) : IPlanPriceRepository
{
    private readonly DatabaseOptions _options = options.Value;

    public async Task<PlanPrices> GetAsync(CancellationToken cancellationToken = default)
    {
        // Rate sirf dikhane ke liye - BB SQL abhi na chala ho to login page na tootey.
        try
        {
            await using var connection = new SqlConnection(_options.ConnectionString);
            return await connection.QuerySingleAsync<PlanPrices>(new CommandDefinition(
                "PUMP.sp_PlanPrices_Get", commandType: System.Data.CommandType.StoredProcedure, cancellationToken: cancellationToken));
        }
        catch (SqlException)
        {
            return new PlanPrices(null, null);
        }
    }

    public async Task<PlanPrices> SaveAsync(decimal? price6Month, decimal? price1Year, long? byUserId, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        return await connection.QuerySingleAsync<PlanPrices>(new CommandDefinition(
            "PUMP.sp_PlanPrices_Save",
            new { Price6Month = price6Month, Price1Year = price1Year, UserId = byUserId },
            commandType: System.Data.CommandType.StoredProcedure, cancellationToken: cancellationToken));
    }
}
