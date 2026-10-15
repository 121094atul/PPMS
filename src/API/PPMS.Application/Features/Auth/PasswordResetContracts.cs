namespace PPMS.Application.Features.Auth;

public sealed record RequestOtpRequest(string Mobile);

public sealed record VerifyOtpRequest(string Mobile, string Otp, string NewPassword);

/// <summary>SP se aane wala jawab. UserId sirf isliye ki API SMS bhej sake.</summary>
public sealed record OtpRequestRow(long? UserId, string? FullName, bool Throttled);

public sealed record OtpVerifyRow(string Result, int? AttemptsLeft);

public interface IPasswordResetRepository
{
    Task<OtpRequestRow> RequestOtpAsync(string mobile, string otpHash, string? sourceIp, CancellationToken cancellationToken = default);
    Task<OtpVerifyRow> VerifyAsync(string mobile, string otpHash, string newPasswordHash, CancellationToken cancellationToken = default);
    Task AdminResetAsync(long userId, string newPasswordHash, long byUserId, CancellationToken cancellationToken = default);
}

/// <summary>
/// OTP bhejne ki koshish ka natija.
///
/// Delivered/NotOurUser me FARAK BAHAR NAHI BATANA — warna koi bhi number daal-daal
/// kar pata kar lega ki kaun sa number system me hai. Dono par ek hi jawab jaata hai.
/// SendFailed alag hai: wo poore system ki haalat hai (SMS hi nahi ja raha), kisi
/// khaas number ke baare me kuch nahi batata, isliye use batana surakshit hai.
/// </summary>
public enum OtpSendOutcome
{
    Delivered,
    NotOurUser,
    Throttled,
    SendFailed,
    SmsNotConfigured
}

public interface IPasswordResetService
{
    /// <summary>
    /// Jawab hamesha ek jaisa dena hai (number registered ho ya na ho), lekin agar
    /// SMS system hi band/kharab hai to user ko batana zaroori hai — warna wo OTP
    /// ka intezaar karta rahega jo kabhi aayega hi nahi.
    /// </summary>
    Task<OtpSendOutcome> RequestOtpAsync(string mobile, string? sourceIp, CancellationToken cancellationToken = default);

    /// <summary>SMS bhejne ka intezaam hai bhi ya nahi (key set hai ya nahi).</summary>
    bool IsSmsConfigured { get; }

    Task<OtpVerifyRow> VerifyAsync(VerifyOtpRequest request, CancellationToken cancellationToken = default);

    Task AdminResetAsync(long userId, string newPassword, long byUserId, CancellationToken cancellationToken = default);
}
