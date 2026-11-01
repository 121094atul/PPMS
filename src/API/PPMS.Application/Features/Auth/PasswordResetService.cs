using System.Security.Cryptography;
using System.Text;
using PPMS.Application.Interfaces;

namespace PPMS.Application.Features.Auth;

public sealed class PasswordResetService(
    IPasswordResetRepository repository,
    IPasswordHasher passwordHasher,
    IWhatsAppNotificationService notificationService,
    INotifySettingsRepository notifySettings,
    IEmailSender emailSender) : IPasswordResetService
{
    /// <summary>
    /// Key set na ho to OTP kahin nahi jaata. Aise me "OTP bhej diya" likhna jhooth
    /// hai — user hamesha ke liye atka rehta hai. Isliye pehle hi jaanch lete hain.
    /// </summary>
    public bool IsSmsConfigured => notificationService.IsOtpConfigured;

    /// <summary>
    /// OTP DB me plain nahi jaata. Agar kabhi DB dikh bhi jaye to us se kisi ka
    /// password reset na kiya ja sake. SHA-256 kaafi hai — OTP 10 minute jeeta hai
    /// aur 5 galat koshish ke baad khud mar jaata hai, isliye yahan PBKDF2 ki
    /// dheemi hashing ki zaroorat nahi (wo har SMS par server ko dheema karti).
    /// </summary>
    private static string HashOtp(string mobile, string otp)
    {
        // Mobile ko saath me mila rahe hain taaki ek hi OTP ka hash do alag numbers
        // par ek jaisa na bane.
        var bytes = Encoding.UTF8.GetBytes($"{mobile}|{otp}");
        return Convert.ToHexString(SHA256.HashData(bytes));
    }

    private static string GenerateOtp()
    {
        // 6 ank, cryptographically random. Random() nahi — wo anumaan lagane layak hai.
        return RandomNumberGenerator.GetInt32(100000, 1000000).ToString();
    }

    public async Task<OtpSendOutcome> RequestOtpAsync(string mobile, string? sourceIp, CancellationToken cancellationToken = default)
    {
        // OTP kis raaste se - Super Admin > Message settings (Section AZ): EMAIL / PROVIDER (SMS-WhatsApp) / OFF.
        // Intezaam hi nahi hai to OTP banana bekaar hai — wo kahin jayega nahi. Sach batao taaki
        // user support ko call kar sake.
        var settings = await notifySettings.GetAsync(cancellationToken);
        var ready = settings.OtpOff ? false : settings.OtpByEmail ? emailSender.IsConfigured : IsSmsConfigured;
        if (!ready)
        {
            return OtpSendOutcome.SmsNotConfigured;
        }

        mobile = await ResolveMobileAsync(mobile, cancellationToken);
        if (mobile.Length < 10)
        {
            // Bahar se kuch nahi batate — jaisa registered number par hota hai waisa hi.
            return OtpSendOutcome.NotOurUser;
        }

        var otp = GenerateOtp();
        var row = await repository.RequestOtpAsync(mobile, HashOtp(mobile, otp), sourceIp, cancellationToken);

        if (row.Throttled)
        {
            return OtpSendOutcome.Throttled;
        }

        if (row.UserId is null)
        {
            return OtpSendOutcome.NotOurUser;
        }

        var message =
            $"PPMS: Your password reset OTP is {otp}. " +
            "It expires in 10 minutes. Do not share it with anyone.";

        // Pehle ye fire-and-forget tha — SMS fail hone par bhi screen "OTP bhej diya"
        // likh deti thi aur user hamesha intezaar karta rehta tha. Ab natija dekhte
        // hain. Thodi der lagti hai, lekin jhoothi tasalli se behtar hai.
        bool sent;
        try
        {
            if (settings.OtpByEmail)
            {
                // Malik ka tenant email (Users me email nahi). Staff / bina email - nahi jaata; bahar wahi
                // aam jawab, aur screen par "OTP nahi aaya? support" ka raasta hai.
                var email = await repository.GetResetEmailAsync(row.UserId.Value, cancellationToken);
                sent = !string.IsNullOrWhiteSpace(email) && await emailSender.SendAsync(
                    email,
                    "PPMS password reset OTP",
                    $"Your PPMS password reset OTP is {otp}.\nIt expires in 10 minutes. Do not share it with anyone.\n\n"
                    + $"आपका PPMS पासवर्ड बदलने का OTP {otp} है। ये 10 मिनट में ख़त्म हो जाएगा। किसी को न बताएँ।\n\n"
                    + "If you did not ask for this, ignore this email.",
                    cancellationToken);
            }
            else
            {
                // OTP ka apna sasta raasta ho sakta hai (Fast2SMS otp route) - baaki sandesh nahi badalte.
                sent = await notificationService.SendOtpAsync(mobile, otp, message, cancellationToken);
            }
        }
        catch (Exception)
        {
            // Provider down / network — user ke liye dono ek hi baat hai.
            sent = false;
        }

        // Fail hone par bahar generic jawab hi jaata hai (warna registered aur
        // anjaan number ka farak pata chal jaata). Operator ko log se pata chalega.
        return sent ? OtpSendOutcome.Delivered : OtpSendOutcome.SendFailed;
    }

    public async Task<OtpVerifyRow> VerifyAsync(VerifyOtpRequest request, CancellationToken cancellationToken = default)
    {
        ValidatePassword(request.NewPassword);
        var mobile = await ResolveMobileAsync(request.Mobile, cancellationToken);

        return await repository.VerifyAsync(
            mobile,
            HashOtp(mobile, request.Otp.Trim()),
            passwordHasher.HashPassword(request.NewPassword),
            cancellationToken);
    }

    public Task AdminResetAsync(long userId, string newPassword, long byUserId, CancellationToken cancellationToken = default)
    {
        ValidatePassword(newPassword);
        return repository.AdminResetAsync(userId, passwordHasher.HashPassword(newPassword), byUserId, cancellationToken);
    }

    private static void ValidatePassword(string password)
    {
        if (string.IsNullOrWhiteSpace(password) || password.Length < 6)
        {
            throw new InvalidOperationException("Password must be at least 6 characters.");
        }

        if (password.Length > 100)
        {
            throw new InvalidOperationException("Password is too long.");
        }
    }

    /// <summary>
    /// Log 9876543210, +91 9876543210, 91-9876543210 — sab tarah likhte hain.
    /// DB me jo hai usse match karana hai, isliye sirf ank rakhte hain aur 10 se
    /// lambe number ka aakhri 10 ank wala hissa lete hain... lekin DB me kuch
    /// numbers 91 ke saath pade hain (jaise 916394389973), isliye poora bhi
    /// aazmate hain — SP dono me se jo mile use uthata hai.
    /// </summary>
    /// <summary>
    /// Forgot-password box me mobile ya email (Section AZ). Email ho to us malik-user ka mobile - aage
    /// sab wahi mobile wala raasta (OTP, rok, jaanch). Na mile to khaali - bahar wahi aam jawab.
    /// </summary>
    private async Task<string> ResolveMobileAsync(string input, CancellationToken cancellationToken)
    {
        if (!string.IsNullOrWhiteSpace(input) && input.Contains('@'))
        {
            var found = await repository.GetMobileForEmailAsync(input.Trim(), cancellationToken);
            return NormalizeMobile(found ?? string.Empty);
        }

        return NormalizeMobile(input);
    }

    private static string NormalizeMobile(string mobile)
    {
        if (string.IsNullOrWhiteSpace(mobile))
        {
            return string.Empty;
        }

        var digits = new string(mobile.Where(char.IsDigit).ToArray());
        return digits;
    }
}
