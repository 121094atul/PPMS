using Microsoft.Extensions.Caching.Memory;

namespace PPMS.Client.Web.Services;

/// <summary>
/// Support ke number (Section AR) - Login, Manual, Shifts page par dikhte hain.
/// Har page par API na jaye, isliye 5 minute cache. Super Admin save kare to turant saaf.
/// </summary>
public sealed class SupportContactService(PPMSApiClient apiClient, IMemoryCache cache)
{
    private const string CacheKey = "support-contacts";
    private static readonly ApiSupportContacts Empty = new(null, null, null);

    public async Task<ApiSupportContacts> GetAsync(CancellationToken ct = default)
    {
        if (cache.TryGetValue(CacheKey, out ApiSupportContacts? cached) && cached is not null)
        {
            return cached;
        }

        var fresh = await apiClient.GetSupportContactsAsync(ct);
        // API na mile to khaali - par chhoti der ke liye, taaki API lautte hi number aa jaye.
        cache.Set(CacheKey, fresh ?? Empty, fresh is null ? TimeSpan.FromSeconds(30) : TimeSpan.FromMinutes(5));
        return fresh ?? Empty;
    }

    public void Invalidate() => cache.Remove(CacheKey);
}
