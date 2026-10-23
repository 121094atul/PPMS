using PPMS.Application.Features.Auth;
using PPMS.Application.Interfaces;

namespace PPMS.Application.Features.Owners;

public sealed class SelfSignupService(
    ISelfSignupRepository repository,
    IPasswordHasher passwordHasher,
    IWhatsAppNotificationService notificationService,
    ISupportContactRepository supportContacts) : ISelfSignupService
{
    private const int TrialDays = 7;

    public async Task<SelfSignupResult> SignupAsync(SelfSignupRequest request, string? sourceIp, CancellationToken cancellationToken = default)
    {
        Validate(request);

        var normalized = request with
        {
            PumpName = request.PumpName.Trim(),
            ContactName = request.ContactName.Trim(),
            ContactNo = new string(request.ContactNo.Where(char.IsDigit).ToArray()),
            Username = request.Username.Trim().ToLowerInvariant()
        };

        var result = await repository.SignupAsync(
            normalized, passwordHasher.HashPassword(request.Password), sourceIp, TrialDays, cancellationToken);

        // Support ka number Super Admin badal sakta hai (Section AR) - code me nahi.
        var support = (await supportContacts.GetAsync(cancellationToken)).Display;
        var message =
            $"Your PPMS account is ready. Username: {normalized.Username}. " +
            $"Your {TrialDays}-day free trial has started." +
            (support is null ? string.Empty : $" For help call {support}.");

        // SMS fail hone se sign-up na rukey — account to ban chuka hai, aur user
        // ko screen par bhi username dikh jaata hai.
        _ = Task.Run(() => notificationService.SendMessageAsync(normalized.ContactNo, message, CancellationToken.None), CancellationToken.None);

        return result;
    }

    private static void Validate(SelfSignupRequest r)
    {
        if (string.IsNullOrWhiteSpace(r.PumpName) || r.PumpName.Trim().Length < 3)
        {
            throw new InvalidOperationException("Pump name must be at least 3 characters.");
        }

        if (string.IsNullOrWhiteSpace(r.ContactName))
        {
            throw new InvalidOperationException("Your name is required.");
        }

        var digits = new string((r.ContactNo ?? string.Empty).Where(char.IsDigit).ToArray());
        if (digits.Length < 10)
        {
            throw new InvalidOperationException("Enter the full 10-digit mobile number.");
        }

        if (string.IsNullOrWhiteSpace(r.Username) || r.Username.Trim().Length < 4)
        {
            throw new InvalidOperationException("Username must be at least 4 characters.");
        }

        // Username login me jaata hai — space ya khaas chinh se dikkat hoti hai.
        if (!r.Username.Trim().All(c => char.IsLetterOrDigit(c) || c is '_' or '.'))
        {
            throw new InvalidOperationException("Username may contain only letters, digits, _ and .");
        }

        if (string.IsNullOrWhiteSpace(r.Password) || r.Password.Length < 6)
        {
            throw new InvalidOperationException("Password must be at least 6 characters.");
        }
    }
}
