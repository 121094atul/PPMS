using Dapper;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;
using PPMS.Application.Features.Subscriptions;
using System.Data;

namespace PPMS.Infrastructure.Persistence;

public sealed class SubscriptionRequestRepository(IOptions<DatabaseOptions> options) : ISubscriptionRequestRepository
{
    private readonly DatabaseOptions _options = options.Value;

    public async Task<long> SaveAsync(SaveSubscriptionRequest request, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        var result = await connection.QuerySingleAsync<long>(
            sql: "PUMP.sp_SubscriptionRequest_Save",
            param: new
            {
                ContactName = request.ContactName,
                ContactNo = request.ContactNo,
                PlanType = request.PlanType,
                OwnerId = request.OwnerId,
                PumpName = request.PumpName,
                SourceIp = request.SourceIp
            },
            commandType: CommandType.StoredProcedure);
        return result;
    }

    public async Task<IReadOnlyList<SubscriptionRequestDto>> GetAllAsync(CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        var items = await connection.QueryAsync<SubscriptionRequestDto>(
            sql: "PUMP.sp_SubscriptionRequest_GetList",
            commandType: CommandType.StoredProcedure);
        return items.ToList();
    }

    public async Task MarkDoneAsync(long id, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        await connection.ExecuteAsync(
            sql: "PUMP.sp_SubscriptionRequest_MarkDone",
            param: new { Id = id },
            commandType: CommandType.StoredProcedure);
    }
}
