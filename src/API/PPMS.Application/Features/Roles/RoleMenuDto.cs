namespace PPMS.Application.Features.Roles;

public sealed record RoleMenuDto(
    long Id,
    long RoleId,
    long MenuId,
    bool CanView,
    bool CanCreate,
    bool CanEdit,
    bool CanDelete
);
