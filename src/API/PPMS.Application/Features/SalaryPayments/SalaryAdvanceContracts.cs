namespace PPMS.Application.Features.SalaryPayments;

/// <summary>
/// Karmchari ka advance (Section AQ5). EntryType: GIVEN (diya), RETURNED (nakad wapas mila),
/// SALARY_CUT (salary me se kata - salary payment se juda, SalaryPaymentId).
///
/// NOTE (CLAUDE.md niyam 5): param theek `sp_EmployeeAdvance_List` ke column ke kram / type se.
/// </summary>
public sealed record EmployeeAdvanceDto(
    long Id,
    long EmployeeId,
    string EmployeeName,
    string EntryType,
    decimal Amount,
    DateTime EntryDate,
    string? PaymentMode,
    string? Notes,
    long? SalaryPaymentId
);

/// <summary>
/// Naya advance diya ya wapas mila. Owner hamesha JWT se.
/// PaymentMode "Drawer" ya ShiftId = galle se: SP us (khuli) shift me Cashbook entry khud likhta hai (Section AT).
/// </summary>
public sealed record SaveEmployeeAdvanceRequest(
    long PumpId,
    long EmployeeId,
    string EntryType,
    decimal Amount,
    DateOnly EntryDate,
    string? PaymentMode,
    string? Notes,
    long? ShiftId = null
);

/// <summary>
/// Mahine ka hisaab (Section AQ6): salary, haath me diya, advance se kata, baaki salary, baaki advance.
///
/// NOTE (CLAUDE.md niyam 5): param theek `sp_Salary_Summary` ke column ke kram / type se.
/// </summary>
public sealed record SalarySummaryDto(
    long EmployeeId,
    string? EmployeeCode,
    string FullName,
    decimal MonthlySalary,
    decimal Paid,
    decimal AdvanceCut,
    decimal Pending,
    decimal AdvanceOutstanding,
    long? SalaryPaymentId
);
