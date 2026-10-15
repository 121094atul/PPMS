namespace PPMS.Application.Features.Auth;

public interface IAuthService
{
    Task<LoginResult?> LoginAsync(LoginRequest request, string? ipAddress, CancellationToken cancellationToken = default);
    Task<LoginResult?> RefreshAsync(RefreshTokenRequest request, CancellationToken cancellationToken = default);
    Task LogoutAsync(LogoutRequest request, CancellationToken cancellationToken = default);
}
