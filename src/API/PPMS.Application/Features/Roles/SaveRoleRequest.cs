namespace PPMS.Application.Features.Roles;

public sealed record SaveRoleRequest(
    long? Id,
    long OwnerId,
    string Name,
    bool IsSystem
);
