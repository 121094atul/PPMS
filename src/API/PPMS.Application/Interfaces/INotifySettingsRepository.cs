namespace PPMS.Application.Interfaces;

/// <summary>
/// Kaun sa sandesh kis raaste se jaaye - Super Admin > Message settings (Section AZ). DB me
/// (AppSettings, OwnerId = 0), isliye badalne par deploy / restart nahi chahiye.
/// </summary>
public interface INotifySettingsRepository
{
    Task<NotifySettings> GetAsync(CancellationToken cancellationToken = default);

    Task<NotifySettings> SaveAsync(string otpChannel, string ownerAlertChannel, long? byUserId, CancellationToken cancellationToken = default);
}

/// <summary>
/// PUMP.sp_NotifySettings_Get. Raaste: EMAIL, PROVIDER (server ki Notification:Provider -
/// SMS / WhatsApp), OFF (sirf OTP: "support ko call karein").
/// </summary>
public sealed record NotifySettings(string OtpChannel, string OwnerAlertChannel)
{
    public const string Email = "EMAIL";
    public const string Provider = "PROVIDER";
    public const string Off = "OFF";

    public static readonly NotifySettings Default = new(Email, Email);

    public bool OtpByEmail => string.Equals(OtpChannel, Email, StringComparison.OrdinalIgnoreCase);
    public bool OtpOff => string.Equals(OtpChannel, Off, StringComparison.OrdinalIgnoreCase);
    public bool OwnerAlertsByEmail => string.Equals(OwnerAlertChannel, Email, StringComparison.OrdinalIgnoreCase);
}

public sealed record SaveNotifySettingsRequest(string OtpChannel, string OwnerAlertChannel);

public sealed record TestEmailRequest(string To);

/// <summary>
/// Email bhejna (SMTP - Gmail app password, Brevo waghairah). Settings server config me
/// (Email:Host / Port / Username / Password / From) - password DB ya code me nahi.
/// </summary>
public interface IEmailSender
{
    bool IsConfigured { get; }

    /// <summary>Kis address se jaata hai - Super Admin page par dikhane ke liye (password nahi).</summary>
    string? FromAddress { get; }

    Task<bool> SendAsync(string to, string subject, string body, CancellationToken cancellationToken = default);

    /// <summary>Ek file ke saath (roz ka backup zip - Section BA).</summary>
    Task<bool> SendWithAttachmentAsync(string to, string subject, string body, string fileName, byte[] content, CancellationToken cancellationToken = default);
}
