namespace PPMS.Client.Web.Services;

/// <summary>
/// API ko grahak ka asli IP bhejta hai (<c>X-PPMS-User-IP</c>). Bina iske API ko har grahak
/// is client server ka IP dikhta tha, aur login / sign-up ki per-IP rok sab par mila kar lagti thi.
/// API ye header sirf hamare apne server se aaya ho tabhi maanti hai (ClientIpForwardingMiddleware).
/// </summary>
public sealed class ForwardUserIpHandler(IHttpContextAccessor accessor) : DelegatingHandler
{
    private const string HeaderName = "X-PPMS-User-IP";

    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        var ip = accessor.HttpContext?.Connection.RemoteIpAddress;
        if (ip is not null)
        {
            if (ip.IsIPv4MappedToIPv6) ip = ip.MapToIPv4();
            request.Headers.Remove(HeaderName);
            request.Headers.TryAddWithoutValidation(HeaderName, ip.ToString());
        }
        return base.SendAsync(request, cancellationToken);
    }
}
