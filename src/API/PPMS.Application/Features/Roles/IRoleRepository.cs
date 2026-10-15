namespace PPMS.Application.Features.Roles;

public interface IRoleRepository
{
    Task<IReadOnlyList<RoleDto>> GetAllAsync(long ownerId, CancellationToken cancellationToken = default);
    Task<long> SaveAsync(SaveRoleRequest request, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<RoleMenuDto>> GetRoleMenusAsync(long roleId, CancellationToken cancellationToken = default);
    Task SaveRoleMenusAsync(SaveRoleMenusRequest request, CancellationToken cancellationToken = default);
}
