namespace PPMS.Application.Features.Staff;

/// <summary>
/// Ek aadmi ka poora record: HR wala hissa (Employees) + uska login (Users), agar hai to.
/// UserId / UserName / RoleId NULL ho sakte hain — bahut se log bina login ke hote hain
/// (chowkidar, helper, safai wala). Ye galti nahi, design hai.
///
/// CLAUDE.md niyam 5: sp_Staff_List ke har column ka yahan param hona zaroori hai.
/// </summary>
public sealed record StaffDto(
    long Id,
    long OwnerId,
    long PumpId,
    long? UserId,
    string EmployeeCode,
    string FullName,
    string? Mobile,
    DateOnly JoinDate,
    string? Designation,
    decimal MonthlySalary,
    bool IsActive,
    string? UserName,
    long? RoleId,
    string? RoleName,
    bool LoginActive
);
