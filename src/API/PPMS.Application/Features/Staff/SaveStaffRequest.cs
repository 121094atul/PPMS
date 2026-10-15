namespace PPMS.Application.Features.Staff;

/// <summary>
/// Ek hi form se employee aur (chaahein to) uska login.
///
/// <para><see cref="WantsLogin"/> false ho to sirf Employees row banti hai aur
/// purana juda hua login sirf ALAG ho jaata hai — mitta nahi. Us login se shift
/// khuli ho sakti hai ya audit me uska naam ho sakta hai.</para>
///
/// <para>Edit karte waqt password khaali chhoda ho to <see cref="Password"/> me
/// <c>***UNCHANGED***</c> bhejein — purana password waisa hi rehta hai.</para>
/// </summary>
public sealed record SaveStaffRequest(
    long? Id,
    long OwnerId,
    long PumpId,
    string EmployeeCode,
    string FullName,
    string? Mobile,
    DateOnly JoinDate,
    string? Designation,
    decimal MonthlySalary,
    bool IsActive,
    bool WantsLogin,
    string? Username,
    string? Password,
    long? RoleId
);

/// <summary>sp_Staff_Save do id lautata hai — banaya gaya employee aur uska login.</summary>
public sealed record SaveStaffResult(long EmployeeId, long? UserId);
