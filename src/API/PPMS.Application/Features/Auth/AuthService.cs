using System.Security.Cryptography;
using System.Text;

namespace PPMS.Application.Features.Auth;

public sealed class AuthService(IAuthRepository repository, ITokenService tokenService, IPasswordHasher passwordHasher) : IAuthService
{
    private static readonly TimeSpan RefreshTokenTtl = TimeSpan.FromDays(7);

    public async Task<LoginResult?> LoginAsync(LoginRequest request, string? ipAddress, CancellationToken cancellationToken = default)
    {
        // Rate limiter IP-partitioned hai, but ek IP se ek hi username ko baar-baar
        // try karna abhi bhi possible tha — isliye per-username lockout bhi zaroori hai.
        var lockStatus = await repository.GetLoginLockStatusAsync(request.Username, cancellationToken);
        if (lockStatus.IsLocked)
        {
            throw new UnauthorizedAccessException($"ACCOUNT_LOCKED:{lockStatus.UnlocksInMinutes}");
        }

        var user = await repository.LoginAsync(request.Username, cancellationToken);
        if (user is null || !passwordHasher.VerifyPassword(request.Password, user.PasswordHash))
        {
            await repository.RecordLoginAttemptAsync(request.Username, ipAddress, isSuccess: false, cancellationToken);
            return null;
        }

        await repository.RecordLoginAttemptAsync(request.Username, ipAddress, isSuccess: true, cancellationToken);

        var (token, accessExpiresOnUtc) = tokenService.GenerateToken(user);
        var refreshToken = GenerateRefreshToken();
        var refreshTokenHash = HashRefreshToken(refreshToken);
        var refreshExpiresOnUtc = DateTime.UtcNow.Add(RefreshTokenTtl);

        EnsureTenantIsUsable(user);


        await repository.SaveRefreshTokenAsync(user.UserId, refreshTokenHash, refreshExpiresOnUtc, cancellationToken);

        return new LoginResult(
            user.UserId,
            user.OwnerId,
            user.FullName,
            user.Username,
            user.RoleId,
            user.RoleName,
            token,
            accessExpiresOnUtc,
            refreshToken,
            refreshExpiresOnUtc,
            user.IsSuperAdmin);
    }

    /// <summary>
    /// Owner suspend/expire to nahi hai. SuperAdmin par laagu nahi hota — usi ko to
    /// suspend hataana hota hai.
    /// </summary>
    private static void EnsureTenantIsUsable(AuthUserRecord user)
    {
        if (user.IsSuperAdmin)
        {
            return;
        }

        // Owner suspend ho chuka hai — subscription khatam, payment nahi hua, ya
        // superadmin ne band kar diya.
        if (!user.OwnerIsActive)
        {
            throw new UnauthorizedAccessException("OWNER_SUSPENDED");
        }

        // Validity nikal gayi.
        var validUpto = user.ValidUpto ?? DateTime.MinValue;
        if (validUpto.Date < DateTime.Today)
        {
            throw new UnauthorizedAccessException("TRIAL_EXPIRED");
        }
    }

    public async Task<LoginResult?> RefreshAsync(RefreshTokenRequest request, CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(request.RefreshToken))
        {
            return null;
        }

        var tokenHash = HashRefreshToken(request.RefreshToken);
        var storedToken = await repository.GetValidRefreshTokenAsync(tokenHash, cancellationToken);
        if (storedToken is null || storedToken.ExpiresOnUtc <= DateTime.UtcNow || storedToken.RevokedOnUtc is not null)
        {
            return null;
        }

        var user = await repository.GetByUserIdAsync(storedToken.UserId, cancellationToken);
        if (user is null)
        {
            return null;
        }

        // Yahi check LOGIN par tha par REFRESH par nahi. Nateeja: jis owner ki
        // subscription khatam ho gayi ya jise superadmin ne suspend kar diya, uske
        // log kaam karte rehte the — refresh token har baar naya ban jaata (7 din ki
        // TTL, har refresh par rotate), isliye unhe dobara login karne ki zaroorat hi
        // nahi padti thi aur suspend/expiry lagta hi nahi tha.
        EnsureTenantIsUsable(user);

        var newRefreshToken = GenerateRefreshToken();
        var newRefreshHash = HashRefreshToken(newRefreshToken);
        var newRefreshExpiresOnUtc = DateTime.UtcNow.Add(RefreshTokenTtl);

        await repository.RevokeRefreshTokenAsync(tokenHash, newRefreshHash, "Rotated", cancellationToken);
        await repository.SaveRefreshTokenAsync(user.UserId, newRefreshHash, newRefreshExpiresOnUtc, cancellationToken);

        var (token, accessExpiresOnUtc) = tokenService.GenerateToken(user);
        return new LoginResult(
            user.UserId,
            user.OwnerId,
            user.FullName,
            user.Username,
            user.RoleId,
            user.RoleName,
            token,
            accessExpiresOnUtc,
            newRefreshToken,
            newRefreshExpiresOnUtc,
            user.IsSuperAdmin);
    }

    public async Task LogoutAsync(LogoutRequest request, CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(request.RefreshToken))
        {
            return;
        }

        var tokenHash = HashRefreshToken(request.RefreshToken);
        await repository.RevokeRefreshTokenAsync(tokenHash, null, "Logout", cancellationToken);
    }

    private static string GenerateRefreshToken()
    {
        var bytes = RandomNumberGenerator.GetBytes(48);
        return Convert.ToBase64String(bytes);
    }

    private static string HashRefreshToken(string refreshToken)
    {
        var bytes = SHA256.HashData(Encoding.UTF8.GetBytes(refreshToken));
        return Convert.ToHexString(bytes);
    }
}
