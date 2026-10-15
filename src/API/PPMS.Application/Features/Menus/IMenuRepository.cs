namespace PPMS.Application.Features.Menus;

public interface IMenuRepository
{
    Task<IReadOnlyList<MenuItemDto>> GetByRoleIdAsync(long roleId, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<MenuItemDto>> GetAllAsync(CancellationToken cancellationToken = default);
}
