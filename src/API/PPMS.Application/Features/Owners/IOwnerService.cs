namespace PPMS.Application.Features.Owners;

public interface IOwnerService
{
    Task<IReadOnlyList<OwnerDto>> GetAllAsync(CancellationToken cancellationToken = default);
    Task<long> SaveAsync(SaveOwnerRequest request, CancellationToken cancellationToken = default);
    Task ToggleStatusAsync(long ownerId, CancellationToken cancellationToken = default);
    Task ExtendTrialAsync(long ownerId, DateTime newValidUpto, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<TenantUserDto>> GetUsersAsync(long ownerId, CancellationToken cancellationToken = default);
}
