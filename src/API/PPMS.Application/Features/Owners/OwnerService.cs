using PPMS.Application.Features.Auth;

namespace PPMS.Application.Features.Owners;

public sealed class OwnerService(IOwnerRepository repository, IPasswordHasher passwordHasher) : IOwnerService
{
    public Task<IReadOnlyList<OwnerDto>> GetAllAsync(CancellationToken cancellationToken = default)
    {
        return repository.GetAllAsync(cancellationToken);
    }

    public Task<long> SaveAsync(SaveOwnerRequest request, CancellationToken cancellationToken = default)
    {
        var hash = passwordHasher.HashPassword(request.AdminPassword);
        return repository.SaveAsync(request.Name, request.AdminUsername, hash, cancellationToken);
    }

    public Task ToggleStatusAsync(long ownerId, CancellationToken cancellationToken = default)
    {
        return repository.ToggleStatusAsync(ownerId, cancellationToken);
    }

    public Task ExtendTrialAsync(long ownerId, DateTime newValidUpto, CancellationToken cancellationToken = default)
    {
        return repository.ExtendTrialAsync(ownerId, newValidUpto, cancellationToken);
    }

    public Task<IReadOnlyList<TenantUserDto>> GetUsersAsync(long ownerId, CancellationToken cancellationToken = default)
    {
        return repository.GetUsersAsync(ownerId, cancellationToken);
    }
}
