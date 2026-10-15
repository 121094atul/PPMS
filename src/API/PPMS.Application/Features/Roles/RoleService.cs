namespace PPMS.Application.Features.Roles;

public sealed class RoleService(IRoleRepository repository) : IRoleService
{
    public Task<IReadOnlyList<RoleDto>> GetAllAsync(long ownerId, CancellationToken cancellationToken = default)
    {
        return repository.GetAllAsync(ownerId, cancellationToken);
    }

    public Task<long> SaveAsync(SaveRoleRequest request, CancellationToken cancellationToken = default)
    {
        return repository.SaveAsync(request, cancellationToken);
    }

    public Task<IReadOnlyList<RoleMenuDto>> GetRoleMenusAsync(long roleId, CancellationToken cancellationToken = default)
    {
        return repository.GetRoleMenusAsync(roleId, cancellationToken);
    }

    public Task SaveRoleMenusAsync(SaveRoleMenusRequest request, CancellationToken cancellationToken = default)
    {
        return repository.SaveRoleMenusAsync(request, cancellationToken);
    }
}
