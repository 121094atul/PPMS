namespace PPMS.Application.Features.Users;

public sealed record SaveUserRequest(
    long? Id,
    long OwnerId,
    string FullName,
    string Username,
    string Password,
    string? Mobile,
    long RoleId
);
