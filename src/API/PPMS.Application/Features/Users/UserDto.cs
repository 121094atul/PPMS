namespace PPMS.Application.Features.Users;

public sealed record UserDto(
    long Id,
    long OwnerId,
    string FullName,
    string Username,
    string? Mobile,
    bool IsActive,
    long? RoleId,
    string? RoleName,
    bool IsSuperAdmin
);
