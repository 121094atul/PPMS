namespace PPMS.Application.Features.Auth;

public interface IAuthRepository
{
    Task<AuthUserRecord?> LoginAsync(string username, CancellationToken cancellationToken = default);
    Task<AuthUserRecord?> GetByUserIdAsync(long userId, CancellationToken cancellationToken = default);
    Task SaveRefreshTokenAsync(long userId, string tokenHash, DateTime expiresOnUtc, CancellationToken cancellationToken = default);
    Task<RefreshTokenRecord?> GetValidRefreshTokenAsync(string tokenHash, CancellationToken cancellationToken = default);
    Task RevokeRefreshTokenAsync(string tokenHash, string? replacedByTokenHash, string? reason, CancellationToken cancellationToken = default);
    Task<LoginLockStatus> GetLoginLockStatusAsync(string username, CancellationToken cancellationToken = default);
    Task RecordLoginAttemptAsync(string username, string? ipAddress, bool isSuccess, CancellationToken cancellationToken = default);
}
