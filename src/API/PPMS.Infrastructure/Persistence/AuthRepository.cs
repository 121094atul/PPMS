using Dapper;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;
using PPMS.Application.Features.Auth;

namespace PPMS.Infrastructure.Persistence;

public sealed class AuthRepository(IOptions<DatabaseOptions> options) : IAuthRepository
{
    private readonly DatabaseOptions _options = options.Value;

    public async Task<AuthUserRecord?> LoginAsync(string username, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        return await connection.QueryFirstOrDefaultAsync<AuthUserRecord>(
            sql: "PUMP.sp_Auth_Login",
            param: new { Username = username },
            commandType: System.Data.CommandType.StoredProcedure);
    }

    public async Task<AuthUserRecord?> GetByUserIdAsync(long userId, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        return await connection.QueryFirstOrDefaultAsync<AuthUserRecord>(
            sql: "PUMP.sp_Auth_GetByUserId",
            param: new { UserId = userId },
            commandType: System.Data.CommandType.StoredProcedure);
    }

    public async Task SaveRefreshTokenAsync(long userId, string tokenHash, DateTime expiresOnUtc, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        await connection.ExecuteAsync(
            sql: "PUMP.sp_RefreshToken_Save",
            param: new
            {
                UserId = userId,
                TokenHash = tokenHash,
                ExpiresOnUtc = expiresOnUtc
            },
            commandType: System.Data.CommandType.StoredProcedure);
    }

    public async Task<RefreshTokenRecord?> GetValidRefreshTokenAsync(string tokenHash, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        return await connection.QueryFirstOrDefaultAsync<RefreshTokenRecord>(
            sql: "PUMP.sp_RefreshToken_GetValid",
            param: new { TokenHash = tokenHash },
            commandType: System.Data.CommandType.StoredProcedure);
    }

    public async Task RevokeRefreshTokenAsync(string tokenHash, string? replacedByTokenHash, string? reason, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        await connection.ExecuteAsync(
            sql: "PUMP.sp_RefreshToken_Revoke",
            param: new
            {
                TokenHash = tokenHash,
                ReplacedByTokenHash = replacedByTokenHash,
                Reason = reason
            },
            commandType: System.Data.CommandType.StoredProcedure);
    }

    public async Task<LoginLockStatus> GetLoginLockStatusAsync(string username, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        var status = await connection.QueryFirstOrDefaultAsync<LoginLockStatus>(
            sql: "PUMP.sp_LoginAttempt_IsLocked",
            param: new { Username = username },
            commandType: System.Data.CommandType.StoredProcedure);

        return status ?? new LoginLockStatus(false, 0, 0);
    }

    public async Task RecordLoginAttemptAsync(string username, string? ipAddress, bool isSuccess, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        await connection.ExecuteAsync(
            sql: "PUMP.sp_LoginAttempt_Record",
            param: new
            {
                Username = username,
                IpAddress = ipAddress,
                IsSuccess = isSuccess
            },
            commandType: System.Data.CommandType.StoredProcedure);
    }
}
