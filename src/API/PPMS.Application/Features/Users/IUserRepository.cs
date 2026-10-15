namespace PPMS.Application.Features.Users;

public interface IUserRepository
{
    Task<IReadOnlyList<UserDto>> GetAllAsync(long ownerId, CancellationToken cancellationToken = default);
    Task<long> SaveAsync(SaveUserRequest request, CancellationToken cancellationToken = default);
    Task DeleteAsync(long id, long ownerId, CancellationToken cancellationToken = default);
}
