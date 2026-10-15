namespace PPMS.Application.Features.Owners;

/// <summary>
/// Tenant (owner) ki poori detail — SuperAdmin panel ke liye.
///
/// NOTE: ye list PUMP.sp_Owner_GetList ke SELECT se bilkul match honi chahiye.
/// Pehle yahan sirf 5 field the jabki SP 16 column deta tha, isliye Dapper
/// materialize hi nahi kar pata tha aur /api/owners hamesha 500 deta tha —
/// matlab SuperAdmin ka poora Tenant Subscriptions page hi nahi khulta tha.
/// </summary>
public sealed record OwnerDto(
    long Id,
    string Name,
    bool IsActive,
    DateTime CreatedOn,
    DateTime? ValidUpto,
    string? ContactName,
    string? ContactNo,
    string? Email,
    string? City,
    string? StateCode,
    string? GSTIN,
    string? PlanCode,
    bool IsTrial,
    int PumpCount,
    int UserCount,
    int? DaysLeft,
    // Ye teen batate hain ki grahak SACH ME istemaal kar raha hai ya nahi.
    // "Aakhri entry" sabse kaam ki - login to koi kabhi bhi kar leta hai,
    // par entry na ho to grahak chhod chuka hai.
    DateTime? LastLoginOn,
    DateTime? LastActivityOn,
    decimal SalesThisMonth
);
