namespace PPMS.Application.Features.Owners;

/// <summary>
/// Login page se naya pump khud account bana sake. Pehle ye sirf ek "request"
/// bhejta tha aur superadmin ko haath se tenant banana padta tha - har naye
/// grahak par uska waqt lagta tha.
/// </summary>
public sealed record SelfSignupRequest(
    string PumpName,
    string ContactName,
    string ContactNo,
    string Username,
    string Password,
    string? City,
    string? StateCode,
    string? Email
);

/// <summary>
/// Field ke naam SP ke column se HUBAHU milne chahiye - Dapper positional record ko
/// constructor se banata hai. sp_Owner_Create ka column "Id" hai (OwnerId nahi),
/// isliye yahan bhi Id hi rakha hai. (Yahi galti pehle 500 de rahi thi.)
/// </summary>
public sealed record SelfSignupResult(long Id, long PumpId, long UserId);

public interface ISelfSignupRepository
{
    Task<SelfSignupResult> SignupAsync(SelfSignupRequest request, string passwordHash, string? sourceIp, int trialDays, CancellationToken cancellationToken = default);
}

public interface ISelfSignupService
{
    Task<SelfSignupResult> SignupAsync(SelfSignupRequest request, string? sourceIp, CancellationToken cancellationToken = default);
}
