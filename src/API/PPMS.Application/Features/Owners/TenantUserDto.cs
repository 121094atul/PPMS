namespace PPMS.Application.Features.Owners;

/// <summary>
/// Superadmin ko kisi tenant ke users chahiye hote hain jab grahak ka phone aata
/// hai "password bhool gaya". Isse sahi user chunkar reset kiya ja sakta hai.
/// </summary>
public sealed record TenantUserDto(
    long Id,
    string FullName,
    string Username,
    string? Mobile,
    bool IsActive,
    bool IsOwner,
    string RoleName,
    DateTime? LastLoginOn
);
