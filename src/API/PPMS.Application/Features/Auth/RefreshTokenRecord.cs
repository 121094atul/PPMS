namespace PPMS.Application.Features.Auth;

public sealed record RefreshTokenRecord(
    long Id,
    long UserId,
    string TokenHash,
    DateTime ExpiresOnUtc,
    DateTime? RevokedOnUtc
);
