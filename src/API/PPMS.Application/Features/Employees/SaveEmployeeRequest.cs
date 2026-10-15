namespace PPMS.Application.Features.Employees;

public sealed record SaveEmployeeRequest(
    long? Id,
    long OwnerId,
    long PumpId,
    long? UserId,
    string EmployeeCode,
    string FullName,
    string? Mobile,
    DateOnly JoinDate,
    string? Designation,
    decimal MonthlySalary,
    bool IsActive
);
