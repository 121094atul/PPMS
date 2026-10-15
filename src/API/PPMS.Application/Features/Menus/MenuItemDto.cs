namespace PPMS.Application.Features.Menus;

public sealed record MenuItemDto(
    long Id,
    long? ParentId,
    string MenuName,
    string Route,
    string? Icon,
    int Sequence,
    bool CanView,
    bool CanCreate,
    bool CanEdit,
    bool CanDelete
);
