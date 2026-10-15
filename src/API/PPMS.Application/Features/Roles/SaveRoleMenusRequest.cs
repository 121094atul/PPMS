namespace PPMS.Application.Features.Roles;

public sealed record SaveRoleMenusRequest(
    long RoleId,
    List<RoleMenuRequestDto> Menus
);

public sealed record RoleMenuRequestDto(
    long MenuId,
    bool CanView,
    bool CanCreate,
    bool CanEdit,
    bool CanDelete
);
