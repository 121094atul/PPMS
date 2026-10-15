namespace PPMS.Application.Features.Auth;

public sealed record AuthUserRecord(
    long UserId,
    long OwnerId,
    string FullName,
    string Username,
    long RoleId,
    string RoleName,
    string PasswordHash,
    bool IsSuperAdmin,
    DateTime? ValidUpto,
    // Owner suspend ho gaya ho to login nahi hona chahiye — pehle ye check tha hi nahi,
    // sirf ValidUpto dekha jaata tha. Superadmin ke liye SP ISNULL(...,1) bhejta hai.
    bool OwnerIsActive,
    string? PlanCode,
    bool IsTrial
);
