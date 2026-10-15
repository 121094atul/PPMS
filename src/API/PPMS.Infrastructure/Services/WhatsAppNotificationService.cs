using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;
using PPMS.Application.Interfaces;
using System.Web;
using Dapper;
using Microsoft.Data.SqlClient;

namespace PPMS.Infrastructure.Services;

public class WhatsAppNotificationService : IWhatsAppNotificationService
{
    private readonly IConfiguration _configuration;
    private readonly ILogger<WhatsAppNotificationService> _logger;
    private readonly HttpClient _httpClient;
    private readonly IOwnerAlertRepository _ownerAlerts;
    private readonly ICreditRepository _credits;

    public WhatsAppNotificationService(
        IConfiguration configuration,
        ILogger<WhatsAppNotificationService> logger,
        HttpClient httpClient,
        IOwnerAlertRepository ownerAlerts,
        ICreditRepository credits)
    {
        _configuration = configuration;
        _logger = logger;
        _httpClient = httpClient;
        _ownerAlerts = ownerAlerts;
        _credits = credits;
    }

    public bool IsConfigured
    {
        get
        {
            var provider = _configuration["Notification:Provider"] ?? _configuration["WhatsApp:Provider"] ?? "Fast2SMS";

            if (string.Equals(provider, "None", StringComparison.OrdinalIgnoreCase))
            {
                return false;
            }

            if (string.Equals(provider, "Fast2SMS", StringComparison.OrdinalIgnoreCase))
            {
                return !string.IsNullOrWhiteSpace(_configuration["Notification:Fast2SMS_ApiKey"]);
            }

            // Bhejne wala code teen naam maanta hai: "Twilio", "TwilioSMS" aur
            // "TwilioWhatsApp". Yahan pehle sirf "Twilio" dekha jaata tha — isliye
            // Provider = TwilioWhatsApp karne par ye false lautata aur password
            // reset ki screen kehti "OTP ka intezaam nahi hai", jabki sandesh
            // bilkul ja sakta tha.
            if (provider.StartsWith("Twilio", StringComparison.OrdinalIgnoreCase))
            {
                return !string.IsNullOrWhiteSpace(_configuration["Notification:Twilio_AccountSid"])
                       && !string.IsNullOrWhiteSpace(_configuration["Notification:Twilio_AuthToken"])
                       && !string.IsNullOrWhiteSpace(_configuration["Notification:Twilio_FromNumber"]);
            }

            return false;
        }
    }

    public async Task<bool> SendToOwnerAsync(long ownerId, string alertKey, string message, CancellationToken cancellationToken = default)
    {
        try
        {
            var target = await _ownerAlerts.GetTargetAsync(ownerId, alertKey, cancellationToken);

            if (target is null)
            {
                _logger.LogWarning("Alert {AlertKey} skipped: owner {OwnerId} not found or inactive.", alertKey, ownerId);
                return false;
            }

            // Owner ne ye alert band kar rakha hai — chup-chaap chhod do, ye galti nahi hai.
            if (!target.IsEnabled)
            {
                return false;
            }

            if (string.IsNullOrWhiteSpace(target.Mobile))
            {
                _logger.LogWarning(
                    "Alert {AlertKey} skipped: no mobile number set for owner {OwnerId} ({OwnerName}). "
                    + "Set it under Settings > Alerts.", alertKey, ownerId, target.OwnerName);
                return false;
            }

            // ---- Credit pehle kaato, TAB bhejo ----
            // Ulta karne par (pehle bhejo, phir kaato) balance khatam hone ke baad
            // bhi sandesh chala jaata — yaani aapke paise se doosre ka sandesh.
            // Isliye pehle kaatte hain; bhejne me gadbad ho to wapas kar dete hain.
            var consumed = await _credits.ConsumeAsync(ownerId, alertKey, cancellationToken);
            if (consumed is null || !consumed.Allowed)
            {
                _logger.LogWarning(
                    "Alert {AlertKey} skipped: owner {OwnerId} ({OwnerName}) has no message credit left. "
                    + "They need to recharge.", alertKey, ownerId, target.OwnerName);
                return false;
            }

            var sent = await SendMessageAsync(target.Mobile, message, cancellationToken);

            if (!sent)
            {
                // Sandesh gaya hi nahi to uska paisa lena galat hai. Wapas kar dete hain.
                try
                {
                    await _credits.RefundAsync(ownerId, alertKey, cancellationToken);
                }
                catch (Exception refundEx)
                {
                    _logger.LogError(refundEx,
                        "Could not refund the message credit for owner {OwnerId} after a failed send.", ownerId);
                }
            }

            return sent;
        }
        catch (Exception ex)
        {
            // Alert na jaane se asli kaam (shift close, sale) nahi rukna chahiye.
            _logger.LogError(ex, "Alert {AlertKey} failed for owner {OwnerId}.", alertKey, ownerId);
            return false;
        }
    }

    public async Task<bool> SendMessageAsync(string phoneNumber, string message, CancellationToken cancellationToken = default)
    {
        try
        {
            var provider = _configuration["Notification:Provider"] ?? _configuration["WhatsApp:Provider"] ?? "Fast2SMS";
            if (provider == "None") return true; // Disabled

            // Fetch owner phone number from database if not provided or empty in settings
            if (string.IsNullOrWhiteSpace(phoneNumber))
            {
                phoneNumber = _configuration["Notification:DefaultOwnerMobile"] ?? _configuration["WhatsApp:DefaultPhoneNumber"] ?? string.Empty;
            }

            // YAHAN PEHLE TENANT KA RISAAV THA:
            //     SELECT TOP 1 Mobile FROM Users WHERE IsOwner = 1
            // Isme OwnerId ka koi filter nahi tha — yaani multi-tenant DB me ye
            // KISI BHI pump ke malik ka number utha leta tha. Nateeja: ek pump ka
            // sandesh (bikri, cash, stock) doosre pump ke malik ke phone par ja
            // sakta tha. Ye chup-chaap hota, kisi ko pata bhi na chalta.
            //
            // Sahi number kiska hai, ye is service ko pata hi nahi (yahan OwnerId
            // aata hi nahi). Isliye ab andaaza lagane ki jagah bhejna hi band kar
            // dete hain — galat aadmi ko bhejne se na bhejna behtar hai.
            if (string.IsNullOrWhiteSpace(phoneNumber))
            {
                _logger.LogWarning(
                    "Notification skipped: no phone number was passed and none is configured. "
                    + "Set Notification:DefaultOwnerMobile, or pass the owner's number explicitly.");
                return false;
            }

            if (string.IsNullOrWhiteSpace(phoneNumber))
            {
                _logger.LogWarning("Notification skipped: No phone number configured.");
                return false;
            }

            if (provider == "TwilioSMS")
            {
                return await SendViaTwilioAsync(phoneNumber, message, false, cancellationToken);
            }
            else if (provider == "TwilioWhatsApp")
            {
                return await SendViaTwilioAsync(phoneNumber, message, true, cancellationToken);
            }
            else if (provider == "Fast2SMS")
            {
                return await SendViaFast2SMSAsync(phoneNumber, message, cancellationToken);
            }

            return false;
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to send WhatsApp message to {Phone}", phoneNumber);
            return false;
        }
    }

    private async Task<bool> SendViaFast2SMSAsync(string phoneNumber, string message, CancellationToken cancellationToken)
    {
        var apiKey = _configuration["Notification:Fast2SMS_ApiKey"];
        if (string.IsNullOrWhiteSpace(apiKey))
        {
            _logger.LogWarning("Fast2SMS API key is not configured.");
            return false;
        }

        // Keep only digits
        var cleanNumber = new string(phoneNumber.Where(char.IsDigit).ToArray());
        if (cleanNumber.StartsWith("91") && cleanNumber.Length == 12) cleanNumber = cleanNumber.Substring(2);

        var url = "https://www.fast2sms.com/dev/bulkV2";
        var request = new HttpRequestMessage(HttpMethod.Post, url);
        request.Headers.Add("authorization", apiKey);
        
        var content = new FormUrlEncodedContent(new[]
        {
            new KeyValuePair<string, string>("route", "q"),
            new KeyValuePair<string, string>("message", message),
            new KeyValuePair<string, string>("language", "english"),
            new KeyValuePair<string, string>("flash", "0"),
            new KeyValuePair<string, string>("numbers", cleanNumber)
        });
        
        request.Content = content;
        var response = await _httpClient.SendAsync(request, cancellationToken);
        
        if (response.IsSuccessStatusCode)
        {
            _logger.LogInformation("SMS sent successfully via Fast2SMS.");
            return true;
        }
        else
        {
            var error = await response.Content.ReadAsStringAsync(cancellationToken);
            _logger.LogError("Fast2SMS API error: {Error}", error);
            // Throwing exception so Visual Studio stops here and shows the EXACT error message to you
            throw new Exception($"Fast2SMS Error: {error}");
        }
    }

    /// <summary>
    /// Twilio ko number hamesha +&lt;country&gt;&lt;number&gt; chahiye.
    ///
    /// <para>Pehle yahan sirf <c>"+" + phoneNumber</c> tha. Bharat me log 10 ank ka
    /// number likhte hain ("9876543210"), jo isse "+9876543210" ban jaata — koi desh
    /// hi nahi. Twilio use chup-chaap reject kar deta aur sandesh kabhi nahi jaata.</para>
    ///
    /// <para>Ab: 10 ank ho to +91 lagta hai; 91 se shuru ho kar 12 ank ho to bas +
    /// lagta hai; jo pehle se + se shuru hai use chhod dete hain.</para>
    /// </summary>
    private static string ToE164(string raw)
    {
        var trimmed = (raw ?? string.Empty).Trim();
        if (trimmed.StartsWith('+'))
        {
            return trimmed;
        }

        var digits = new string(trimmed.Where(char.IsDigit).ToArray());

        if (digits.Length == 10)
        {
            return "+91" + digits;                      // seedha 10 ank
        }

        if (digits.Length == 12 && digits.StartsWith("91"))
        {
            return "+" + digits;                        // 91 pehle se laga hai
        }

        if (digits.Length == 11 && digits.StartsWith("0"))
        {
            return "+91" + digits[1..];                 // STD wala 0 hata do
        }

        return "+" + digits;                            // baaki: jaisa hai waisa
    }

    private async Task<bool> SendViaTwilioAsync(string phoneNumber, string message, bool isWhatsApp, CancellationToken cancellationToken)
    {
        var accountSid = _configuration["Notification:Twilio_AccountSid"];
        var authToken = _configuration["Notification:Twilio_AuthToken"];
        var fromNumber = _configuration["Notification:Twilio_FromNumber"];

        if (string.IsNullOrWhiteSpace(accountSid) || string.IsNullOrWhiteSpace(authToken) || string.IsNullOrWhiteSpace(fromNumber))
        {
            _logger.LogWarning("Twilio credentials are not configured.");
            return false;
        }

        var url = $"https://api.twilio.com/2010-04-01/Accounts/{accountSid}/Messages.json";
        var request = new HttpRequestMessage(HttpMethod.Post, url);
        var authString = Convert.ToBase64String(System.Text.Encoding.ASCII.GetBytes($"{accountSid}:{authToken}"));
        request.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Basic", authString);

        phoneNumber = ToE164(phoneNumber);
        
        var toParam = isWhatsApp ? $"whatsapp:{phoneNumber}" : phoneNumber;
        var fromParam = isWhatsApp && !fromNumber.StartsWith("whatsapp:") ? $"whatsapp:{fromNumber}" : fromNumber;

        var fields = new List<KeyValuePair<string, string>>
        {
            new("To", toParam),
            new("From", fromParam)
        };

        // WhatsApp par do tarah ke sandesh hote hain:
        //
        //   * FREEFORM (seedha Body) — sirf tab chalta hai jab grahak ne pichle
        //     24 ghante me aapko WhatsApp kiya ho. Test ke liye yahi kaafi hai.
        //   * TEMPLATE (ContentSid) — jab aap pehle sandesh bhej rahe hon.
        //     Meta se pehle approve karana padta hai.
        //
        // Pump ke alert hamesha hamari taraf se shuru hote hain, isliye asli kaam
        // me template hi chalega. ContentSid set ho to wahi bhejte hain.
        var contentSid = _configuration["Notification:Twilio_ContentSid"];
        if (isWhatsApp && !string.IsNullOrWhiteSpace(contentSid))
        {
            fields.Add(new KeyValuePair<string, string>("ContentSid", contentSid));
            // Template me {{1}} ki jagah hamara poora sandesh chala jaata hai.
            fields.Add(new KeyValuePair<string, string>(
                "ContentVariables",
                System.Text.Json.JsonSerializer.Serialize(new Dictionary<string, string> { ["1"] = message })));
        }
        else
        {
            fields.Add(new KeyValuePair<string, string>("Body", message));
        }

        request.Content = new FormUrlEncodedContent(fields);
        var response = await _httpClient.SendAsync(request, cancellationToken);

        if (response.IsSuccessStatusCode)
        {
            _logger.LogInformation("{Channel} sent via Twilio to {To}.", isWhatsApp ? "WhatsApp" : "SMS", toParam);
            return true;
        }

        var error = await response.Content.ReadAsStringAsync(cancellationToken);

        // Twilio ka jawab JSON hota hai jisme "code" hota hai. Bina use padhe
        // sirf "Twilio API error" log hota tha — jisse ye pata hi nahi chalta ki
        // galti number ki hai, template ki hai, ya paise ki. Aam wajahon ka
        // seedha matlab likh dete hain.
        var hint = error switch
        {
            _ when error.Contains("\"code\": 63016") || error.Contains("\"code\":63016")
                => "WhatsApp ne freeform sandesh mana kiya. Aisa tab hota hai jab grahak ne pichle 24 ghante me aapko message na kiya ho. "
                   + "Test ke liye: us number se pehle Twilio ke number par koi bhi message bhejein. Asli kaam ke liye: approved template ka ContentSid set karein "
                   + "(Notification__Twilio_ContentSid).",
            _ when error.Contains("63007")
                => "Twilio par ye 'From' number WhatsApp ke liye chaalu nahi hai. Notification__Twilio_FromNumber dobara dekhein.",
            _ when error.Contains("21608") || error.Contains("21211")
                => "Trial account: sirf verify kiye hue number par hi sandesh ja sakta hai. Twilio console me wo number verify karein.",
            _ when error.Contains("20003")
                => "Twilio ne login hi nahi maana. AccountSid / AuthToken dobara dekhein.",
            _ => null
        };

        if (hint is not null)
        {
            _logger.LogError("Twilio ne sandesh nahi bheja. {Hint} (Twilio ka jawab: {Error})", hint, error);
        }
        else
        {
            _logger.LogError("Twilio API error: {Error}", error);
        }

        return false;
    }
}
