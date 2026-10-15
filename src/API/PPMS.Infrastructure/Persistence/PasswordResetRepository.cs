using System.Data;
using Dapper;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;
using PPMS.Application.Features.Auth;

namespace PPMS.Infrastructure.Persistence;

public sealed class PasswordResetRepository(IOptions<DatabaseOptions> options) : IPasswordResetRepository
{
    private readonly DatabaseOptions _options = options.Value;

    public async Task<OtpRequestRow> RequestOtpAsync(string mobile, string otpHash, string? sourceIp, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        return await connection.QuerySingleAsync<OtpRequestRow>(
            sql: "PUMP.sp_PasswordReset_RequestOtp",
            param: new { Mobile = mobile, OtpHash = otpHash, SourceIp = sourceIp },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<OtpVerifyRow> VerifyAsync(string mobile, string otpHash, string newPasswordHash, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        return await connection.QuerySingleAsync<OtpVerifyRow>(
            sql: "PUMP.sp_PasswordReset_Verify",
            param: new { Mobile = mobile, OtpHash = otpHash, NewPasswordHash = newPasswordHash },
            commandType: CommandType.StoredProcedure);
    }

    public async Task AdminResetAsync(long userId, string newPasswordHash, long byUserId, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        await connection.ExecuteAsync(
            sql: "PUMP.sp_User_AdminResetPassword",
            param: new { UserId = userId, NewPasswordHash = newPasswordHash, ByUserId = byUserId },
            commandType: CommandType.StoredProcedure);
    }
}
