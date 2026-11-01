using System.Net;
using System.Net.Mail;
using System.Text;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using PPMS.Application.Interfaces;

namespace PPMS.Infrastructure.Services;

public sealed class EmailOptions
{
    public const string SectionName = "Email";

    /// <summary>SMTP server - Gmail: smtp.gmail.com, Brevo: smtp-relay.brevo.com.</summary>
    public string? Host { get; set; }

    /// <summary>587 (STARTTLS). 465 wala "implicit SSL" .NET ka SmtpClient nahi chalata.</summary>
    public int Port { get; set; } = 587;

    public bool EnableSsl { get; set; } = true;

    public string? Username { get; set; }

    /// <summary>Gmail me apna password nahi - "App password" (Google account > Security). Sirf server env me.</summary>
    public string? Password { get; set; }

    /// <summary>Kis address se jaaye. Khaali ho to Username.</summary>
    public string? From { get; set; }

    public string FromName { get; set; } = "PPMS";
}

/// <summary>
/// Email (Section AZ) - password OTP aur malik ke alert. Muft hai, isliye credit nahi katta.
/// </summary>
public sealed class SmtpEmailSender(IOptions<EmailOptions> options, ILogger<SmtpEmailSender> logger) : IEmailSender
{
    private readonly EmailOptions _o = options.Value;

    public bool IsConfigured => !string.IsNullOrWhiteSpace(_o.Host) && !string.IsNullOrWhiteSpace(FromAddress);

    public string? FromAddress => string.IsNullOrWhiteSpace(_o.From) ? _o.Username : _o.From;

    public Task<bool> SendAsync(string to, string subject, string body, CancellationToken cancellationToken = default)
        => SendCoreAsync(to, subject, body, null, null, cancellationToken);

    public Task<bool> SendWithAttachmentAsync(string to, string subject, string body, string fileName, byte[] content, CancellationToken cancellationToken = default)
        => SendCoreAsync(to, subject, body, fileName, content, cancellationToken);

    private async Task<bool> SendCoreAsync(string to, string subject, string body, string? fileName, byte[]? content, CancellationToken cancellationToken)
    {
        if (!IsConfigured)
        {
            logger.LogWarning("Email not sent: Email:Host / Email:From are not set on the server.");
            return false;
        }

        if (string.IsNullOrWhiteSpace(to))
        {
            return false;
        }

        try
        {
            using var message = new MailMessage
            {
                From = new MailAddress(FromAddress!, _o.FromName, Encoding.UTF8),
                Subject = subject,
                SubjectEncoding = Encoding.UTF8,
                Body = body,
                BodyEncoding = Encoding.UTF8,
                IsBodyHtml = false
            };
            message.To.Add(new MailAddress(to.Trim()));

            // MailMessage dispose hone par stream bhi band - isliye using nahi.
            if (fileName is not null && content is not null)
            {
                message.Attachments.Add(new Attachment(new MemoryStream(content), fileName, "application/zip"));
            }

            using var client = new SmtpClient(_o.Host, _o.Port)
            {
                EnableSsl = _o.EnableSsl,
                DeliveryMethod = SmtpDeliveryMethod.Network,
                // Backup ki file badi ho sakti hai - kamzor upload par 20 second kam padte.
                Timeout = content is null ? 20000 : 120000
            };
            if (!string.IsNullOrWhiteSpace(_o.Username))
            {
                client.Credentials = new NetworkCredential(_o.Username, _o.Password);
            }

            await client.SendMailAsync(message, cancellationToken);
            logger.LogInformation("Email sent ({Subject}).", subject);
            return true;
        }
        catch (Exception ex) when (ex is SmtpException or FormatException or InvalidOperationException)
        {
            // Galat password / host / address - asli wajah log me; bahar sirf "nahi gaya".
            logger.LogError(ex, "Email could not be sent ({Subject}).", subject);
            return false;
        }
    }
}
