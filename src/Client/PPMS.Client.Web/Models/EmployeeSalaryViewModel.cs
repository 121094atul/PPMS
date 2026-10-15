using PPMS.Client.Web.Services;

namespace PPMS.Client.Web.Models;

public sealed class EmployeeManagementViewModel
{
    public EmployeeForm Form { get; set; } = new();
    public IReadOnlyList<ApiPumpDto> Pumps { get; set; } = Array.Empty<ApiPumpDto>();
    public IReadOnlyList<ApiUserDto> Users { get; set; } = Array.Empty<ApiUserDto>();
    public IReadOnlyList<ApiEmployeeDto> Employees { get; set; } = Array.Empty<ApiEmployeeDto>();
    public string? Message { get; set; }
}

public sealed class EmployeeForm
{
    public long? Id { get; set; }
    public long OwnerId { get; set; }
    public long PumpId { get; set; }
    public long? UserId { get; set; }
    public string EmployeeCode { get; set; } = string.Empty;
    public string FullName { get; set; } = string.Empty;
    public string? Mobile { get; set; }
    public DateOnly JoinDate { get; set; } = DateOnly.FromDateTime(DateTime.Today);
    public string? Designation { get; set; }
    public decimal MonthlySalary { get; set; }
    public bool IsActive { get; set; } = true;
}

public sealed class SalaryManagementViewModel
{
    public SalaryPaymentForm Form { get; set; } = new();
    public IReadOnlyList<ApiPumpDto> Pumps { get; set; } = Array.Empty<ApiPumpDto>();
    public IReadOnlyList<ApiEmployeeDto> Employees { get; set; } = Array.Empty<ApiEmployeeDto>();
    public IReadOnlyList<ApiSalaryPaymentDto> Payments { get; set; } = Array.Empty<ApiSalaryPaymentDto>();
    public string? Message { get; set; }
    public int SalaryYear { get; set; } = DateTime.Today.Year;
    public int SalaryMonth { get; set; } = DateTime.Today.Month;
}

public sealed class SalaryPaymentForm
{
    public long? Id { get; set; }
    public long OwnerId { get; set; }
    public long PumpId { get; set; }
    public long EmployeeId { get; set; }
    public int SalaryYear { get; set; } = DateTime.Today.Year;
    public int SalaryMonth { get; set; } = DateTime.Today.Month;
    public decimal Amount { get; set; }
    public DateOnly PaidOn { get; set; } = DateOnly.FromDateTime(DateTime.Today);
    public string PaymentMode { get; set; } = "Cash";
    public string? ReferenceNo { get; set; }
    public string? Notes { get; set; }
}
