using System.Data;
using Dapper;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;
using PPMS.Application.Features.Owners;

namespace PPMS.Infrastructure.Persistence;

public sealed class SelfSignupRepository(IOptions<DatabaseOptions> options) : ISelfSignupRepository
{
    private readonly DatabaseOptions _options = options.Value;

    public async Task<SelfSignupResult> SignupAsync(
        SelfSignupRequest request, string passwordHash, string? sourceIp, int trialDays,
        CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        return await connection.QuerySingleAsync<SelfSignupResult>(
            sql: "PUMP.sp_Owner_SelfSignup",
            param: new
            {
                request.PumpName,
                request.ContactName,
                request.ContactNo,
                AdminUsername = request.Username,
                AdminPasswordHash = passwordHash,
                request.City,
                request.StateCode,
                request.Email,
                SourceIp = sourceIp,
                TrialDays = trialDays
            },
            commandType: CommandType.StoredProcedure);
    }
}
