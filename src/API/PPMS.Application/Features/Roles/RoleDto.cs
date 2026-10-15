namespace PPMS.Application.Features.Roles;

public sealed record RoleDto(
    long Id,
    long OwnerId,
    string Name,
    bool IsSystem,
    bool IsActive
);
