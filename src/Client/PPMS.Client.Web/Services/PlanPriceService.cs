using Microsoft.Extensions.Caching.Memory;

namespace PPMS.Client.Web.Services;

/// <summary>
/// Login page par plan ka rate (Section BB) - support number jaisa: 5 minute cache, Super Admin save
/// kare to turant saaf.
/// </summary>
public sealed class PlanPriceService(PPMSApiClient apiClient, IMemoryCache cache)
{
    private const string CacheKey = "plan-prices";
    private static readonly ApiPlanPrices Empty = new(null, null);

    public async Task<ApiPlanPrices> GetAsync(CancellationToken ct = default)
    {
        if (cache.TryGetValue(CacheKey, out ApiPlanPrices? cached) && cached is not null)
        {
            return cached;
        }

        var fresh = await apiClient.GetPlanPricesAsync(ct);
        cache.Set(CacheKey, fresh ?? Empty, fresh is null ? TimeSpan.FromSeconds(30) : TimeSpan.FromMinutes(5));
        return fresh ?? Empty;
    }

    public void Invalidate() => cache.Remove(CacheKey);

    /// <summary>₹ ke saath, Indian commas (₹4,999). Paise sirf tab jab hon.</summary>
    public static string Format(decimal price)
    {
        var inr = System.Globalization.CultureInfo.GetCultureInfo("en-IN");
        return "₹" + price.ToString(price == decimal.Truncate(price) ? "#,##0" : "#,##0.00", inr);
    }
}
