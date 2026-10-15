namespace PPMS.Application.Features.Auth;

public sealed record LoginResult(
    long UserId,
    long OwnerId,
    string FullName,
    string Username,
    long RoleId,
    string RoleName,
    string Token,
    DateTime AccessTokenExpiresOnUtc,
    string RefreshToken,
    DateTime RefreshTokenExpiresOnUtc,
    bool IsSuperAdmin
);
