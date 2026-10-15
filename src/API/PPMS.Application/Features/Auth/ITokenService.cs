namespace PPMS.Application.Features.Auth;

public interface ITokenService
{
    (string Token, DateTime ExpiresOnUtc) GenerateToken(AuthUserRecord user);
}
