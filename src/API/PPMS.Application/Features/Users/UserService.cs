using PPMS.Application.Features.Auth;

namespace PPMS.Application.Features.Users;

public sealed class UserService(IUserRepository repository, IPasswordHasher passwordHasher) : IUserService
{
    public Task<IReadOnlyList<UserDto>> GetAllAsync(long ownerId, CancellationToken cancellationToken = default)
    {
        return repository.GetAllAsync(ownerId, cancellationToken);
    }

    public Task<long> SaveAsync(SaveUserRequest request, CancellationToken cancellationToken = default)
    {
        // If password is the "unchanged" placeholder, pass it through as-is.
        // The stored procedure should detect this and skip updating PasswordHash.
        var safeRequest = string.Equals(request.Password, "***UNCHANGED***", StringComparison.Ordinal)
            ? request
            : request with
            {
                Password = passwordHasher.HashPassword(request.Password)
            };

        return repository.SaveAsync(safeRequest, cancellationToken);
    }

    public Task DeleteAsync(long id, long ownerId, CancellationToken cancellationToken = default)
    {
        return repository.DeleteAsync(id, ownerId, cancellationToken);
    }
}
