using System.Net;
using System.Net.NetworkInformation;

namespace PPMS.Api.Middleware;

/// <summary>
/// Grahak ka asli IP, jab request hamare apne client (MVC) server se aaye.
///
/// <para>Login / sign-up browser se seedha API par nahi aate - pehle client server par, phir wo API
/// ko bulata hai. Isliye API ko har grahak ka IP client server ka hi dikhta tha (live par 60 din me
/// 140 me se 138 login ek hi IP se darj the). Nateeja: "ek IP se minute me 10 login" aur "ghante me
/// 5 sign-up" wali rok POORE software par mila kar lagti thi - ek aadmi galat password daale to
/// baaki sab bhi ruk jaate, aur ad ke din ghante me sirf 5 trial ban paate.</para>
///
/// <para>Ab client har request ke saath <c>X-PPMS-User-IP</c> bhejta hai. Ye header tabhi maana jaata
/// hai jab request isi machine se (loopback / isi machine ka koi IP) ya
/// <c>Security:TrustedClientIps</c> me likhe IP se aaye - bahar se koi nakli header bhej kar rok
/// nahi tod sakta. Baaki sab (rate limit, LoginAttempts, SourceIp) apne aap sahi IP dekhte hain.</para>
/// </summary>
public sealed class ClientIpForwardingMiddleware
{
    public const string HeaderName = "X-PPMS-User-IP";

    private readonly RequestDelegate _next;
    private readonly HashSet<IPAddress> _trusted;
    private readonly bool _trustLocal;
    private readonly ILogger<ClientIpForwardingMiddleware> _logger;
    private static int _warned;

    public ClientIpForwardingMiddleware(RequestDelegate next, IConfiguration configuration, ILogger<ClientIpForwardingMiddleware> logger)
    {
        _next = next;
        _logger = logger;
        _trustLocal = !string.Equals(configuration["Security:TrustLocalClientIp"], "false", StringComparison.OrdinalIgnoreCase);
        _trusted = new HashSet<IPAddress>();

        foreach (var part in (configuration["Security:TrustedClientIps"] ?? string.Empty)
                     .Split(new[] { ',', ';', ' ' }, StringSplitOptions.RemoveEmptyEntries))
        {
            if (IPAddress.TryParse(part, out var ip)) _trusted.Add(Normalize(ip));
        }

        if (_trustLocal)
        {
            try
            {
                foreach (var ni in NetworkInterface.GetAllNetworkInterfaces())
                {
                    foreach (var addr in ni.GetIPProperties().UnicastAddresses)
                    {
                        _trusted.Add(Normalize(addr.Address));
                    }
                }
            }
            catch (Exception ex)
            {
                // Machine ke IP na padh paaye to bas loopback - pehle jaisa vyavhaar, koi nuksaan nahi.
                logger.LogWarning(ex, "Could not read local IP addresses for client IP forwarding.");
            }
        }
    }

    private static IPAddress Normalize(IPAddress ip) => ip.IsIPv4MappedToIPv6 ? ip.MapToIPv4() : ip;

    public Task InvokeAsync(HttpContext context)
    {
        var header = context.Request.Headers[HeaderName].ToString();
        if (!string.IsNullOrWhiteSpace(header))
        {
            var remote = context.Connection.RemoteIpAddress;
            var fromUs = remote is not null
                         && ((_trustLocal && IPAddress.IsLoopback(remote)) || _trusted.Contains(Normalize(remote)));

            if (fromUs && IPAddress.TryParse(header.Split(',')[0].Trim(), out var userIp))
            {
                context.Connection.RemoteIpAddress = Normalize(userIp);
            }
            else if (!fromUs && Interlocked.Exchange(ref _warned, 1) == 0)
            {
                // Ek hi baar: live par hamara client kisi aur IP se aata ho to yahin pata chalega -
                // wo IP Security:TrustedClientIps me daal dein.
                _logger.LogWarning("{Header} came from {Remote}, which is not trusted - ignored. "
                    + "If this is our own client server, add it to Security:TrustedClientIps.", HeaderName, remote);
            }

            // Aage koi isse na padhe (maana ho ya na maana ho).
            context.Request.Headers.Remove(HeaderName);
        }

        return _next(context);
    }
}
