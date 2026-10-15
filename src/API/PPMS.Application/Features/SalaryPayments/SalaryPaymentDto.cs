namespace PPMS.Application.Features.SalaryPayments;

public sealed record SalaryPaymentDto(
    long Id,
    long OwnerId,
    long PumpId,
    long EmployeeId,
    string EmployeeCode,
    string EmployeeName,
    int SalaryYear,
    int SalaryMonth,
    decimal Amount,
    DateOnly PaidOn,
    string PaymentMode,
    string? ReferenceNo,
    string? Notes,
    DateTime CreatedOn
);
