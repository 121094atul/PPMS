namespace PPMS.Application.Features.Menus;

public sealed class MenuQueryService(IMenuRepository repository) : IMenuQueryService
{
    public Task<IReadOnlyList<MenuItemDto>> GetByRoleIdAsync(long roleId, CancellationToken cancellationToken = default)
    {
        return repository.GetByRoleIdAsync(roleId, cancellationToken);
    }

    public Task<IReadOnlyList<MenuItemDto>> GetAllAsync(CancellationToken cancellationToken = default)
    {
        return repository.GetAllAsync(cancellationToken);
    }
}
