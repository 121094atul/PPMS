using PPMS.Client.Web.Services;

namespace PPMS.Client.Web.Models;

/// <summary>
/// Staff page — ek hi form se aadmi ka HR record aur (chaahein to) uska login.
///
/// <para>Pehle ye do alag page the: /Operations/Users par login banao, phir
/// /Operations/Employees par employee banao aur dono ko haath se jodo. Naam aur
/// mobile dono jagah alag-alag bharna padta tha, aur sync ka koi rasta nahi tha.</para>
///
/// <para>Tables ab bhi do hi hain (Users owner-level login hai, Employees pump-level
/// HR record) — ye theek hai, kyunki har user employee nahi hota (owner, auditor,
/// accountant) aur har employee ka login nahi hota (chowkidar, helper). Sirf FORM
/// ek ho gaya hai.</para>
/// </summary>
public sealed class StaffManagementViewModel
{
    public StaffForm Form { get; set; } = new();
    public IReadOnlyList<ApiPumpDto> Pumps { get; set; } = Array.Empty<ApiPumpDto>();
    public IReadOnlyList<ApiRoleDto> Roles { get; set; } = Array.Empty<ApiRoleDto>();
    public IReadOnlyList<ApiStaffDto> Staff { get; set; } = Array.Empty<ApiStaffDto>();
    public string? Message { get; set; }
}

public sealed class StaffForm
{
    /// <summary>Employees.Id — naya aadmi ho to null.</summary>
    public long? Id { get; set; }

    public long OwnerId { get; set; }
    public long PumpId { get; set; }
    public string EmployeeCode { get; set; } = string.Empty;
    public string FullName { get; set; } = string.Empty;
    public string? Mobile { get; set; }
    public DateOnly JoinDate { get; set; } = DateOnly.FromDateTime(DateTime.Today);
    public string? Designation { get; set; }
    public decimal MonthlySalary { get; set; }
    public bool IsActive { get; set; } = true;

    /// <summary>Form ka checkbox: "Isko software me login bhi dena hai".</summary>
    public bool WantsLogin { get; set; }

    public string? Username { get; set; }

    /// <summary>
    /// Edit karte waqt khaali chhoda jaye to purana password waisa hi rehta hai.
    /// Controller aise me <c>***UNCHANGED***</c> bhejta hai.
    /// </summary>
    public string? Password { get; set; }

    public long? RoleId { get; set; }

    /// <summary>Sirf dikhane ke liye — is aadmi ka login pehle se juda hai ya nahi.</summary>
    public bool HasExistingLogin { get; set; }
}
