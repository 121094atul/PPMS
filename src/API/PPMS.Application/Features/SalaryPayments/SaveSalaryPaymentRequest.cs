namespace PPMS.Application.Features.SalaryPayments;

public sealed record SaveSalaryPaymentRequest(
    long? Id,
    long OwnerId,
    long PumpId,
    long EmployeeId,
    int SalaryYear,
    int SalaryMonth,
    decimal Amount,
    DateOnly PaidOn,
    string PaymentMode,
    string? ReferenceNo,
    string? Notes
);
