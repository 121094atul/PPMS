using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.AspNetCore.Http.Extensions;
using Microsoft.Extensions.Options;

namespace PPMS.Api.Tenancy;

/// <summary>
/// Multi-tenant isolation ka darwaza.
///
/// PROBLEM JO YE THEEK KARTA HAI
/// -----------------------------
/// Pehle API client ka bheja hua ownerId bina check kiye maan leti thi — do jagah se:
///
///   1. Query string : GET /api/party-ledger?ownerId=47&amp;pumpId=12
///                     ResolveOwnerId() me `if (requestedOwnerId is > 0) return requestedOwnerId.Value;`
///                     Yaani koi bhi logged-in user URL me number badal kar kisi bhi
///                     doosre pump ka ledger, sales aur outstanding padh sakta tha.
///
///   2. Request body : POST /api/parties  { "ownerId": 47, ... }
///                     POST wale endpoints to ResolveOwnerId() call hi nahi karte the —
///                     request body seedha service me chala jaata tha. Yaani read hi
///                     nahi, WRITE bhi doosre owner ke naam par ho sakta tha.
///
/// SOLUTION
/// --------
/// Ye middleware authentication ke turant baad chalta hai aur dono raste band karta hai:
///   * query string ka ownerId  -> token wale se replace
///   * JSON body ka OwnerId     -> token wale se replace (root object me add bhi kar deta hai)
///
/// Non-superadmin user agar apne se alag ownerId bhejta hai to ye ek IDOR koshish hai.
/// Strict mode (default) me 403 milta hai; warna value chup-chaap sudhar jaati hai.
/// Dono soorat me security barabar hai — value ka koi asar nahi padta. Farq sirf
/// detection ka hai.
///
/// Superadmin ko chhoot hai — usse doosre owners ka data dekhna hi hota hai.
/// </summary>
public sealed class TenantIsolationMiddleware(
    RequestDelegate next,
    ILogger<TenantIsolationMiddleware> logger,
    IOptions<TenantOptions> options)
{
    private const string OwnerIdKey = "OwnerId";
    private const string OwnerIdQueryKey = "ownerId";

    private readonly TenantOptions _options = options.Value;

    public async Task InvokeAsync(HttpContext context, TenantContext tenant)
    {
        tenant.PopulateFrom(context.User);

        // Anonymous endpoints (login, refresh, subscription request) — kuch nahi karna.
        if (!tenant.IsResolved)
        {
            await next(context);
            return;
        }

        // Superadmin cross-owner kaam karta hai, usse rokna nahi.
        if (tenant.IsSuperAdmin)
        {
            await next(context);
            return;
        }

        if (!TryEnforceQueryString(context, tenant))
        {
            await WriteForbiddenAsync(context, "ownerId (query string)");
            return;
        }

        var bodyResult = await TryEnforceJsonBodyAsync(context, tenant);
        if (bodyResult == EnforcementResult.Rejected)
        {
            await WriteForbiddenAsync(context, "OwnerId (request body)");
            return;
        }

        await next(context);
    }

    // ---------------------------------------------------------------------------------
    // Query string
    // ---------------------------------------------------------------------------------
    private bool TryEnforceQueryString(HttpContext context, TenantContext tenant)
    {
        if (!context.Request.Query.TryGetValue(OwnerIdQueryKey, out var raw))
        {
            return true;
        }

        var value = raw.ToString();

        // 0 / khaali / bakwas = "specified nahi". ResolveOwnerId claim se bhar dega.
        if (!long.TryParse(value, out var requested) || requested <= 0 || requested == tenant.OwnerId)
        {
            return true;
        }

        logger.LogWarning(
            "Tenant isolation: user {UserId} ({Username}, owner {OwnerId}) ne query string me ownerId={RequestedOwnerId} bheja. Path {Path}",
            tenant.UserId, tenant.Username, tenant.OwnerId, requested, context.Request.Path);

        if (_options.StrictMode)
        {
            return false;
        }

        // Non-strict: value ko token wale se replace kar do.
        var rebuilt = new QueryBuilder();
        foreach (var pair in context.Request.Query)
        {
            if (string.Equals(pair.Key, OwnerIdQueryKey, StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            foreach (var v in pair.Value)
            {
                rebuilt.Add(pair.Key, v ?? string.Empty);
            }
        }

        rebuilt.Add(OwnerIdQueryKey, tenant.OwnerId.ToString());

        context.Request.QueryString = rebuilt.ToQueryString();
        return true;
    }

    // ---------------------------------------------------------------------------------
    // JSON body
    // ---------------------------------------------------------------------------------
    private async Task<EnforcementResult> TryEnforceJsonBodyAsync(HttpContext context, TenantContext tenant)
    {
        if (!HttpMethods.IsPost(context.Request.Method)
            && !HttpMethods.IsPut(context.Request.Method)
            && !HttpMethods.IsPatch(context.Request.Method))
        {
            return EnforcementResult.Unchanged;
        }

        var contentType = context.Request.ContentType;
        if (contentType is null || !contentType.Contains("json", StringComparison.OrdinalIgnoreCase))
        {
            return EnforcementResult.Unchanged;
        }

        if (context.Request.ContentLength is 0)
        {
            return EnforcementResult.Unchanged;
        }

        // Memory abuse se bachne ke liye cap. Isse bada JSON body is app me nahi aata.
        if (context.Request.ContentLength > _options.MaxInspectedBodyBytes)
        {
            logger.LogWarning(
                "Tenant isolation: body {Length} bytes ka hai, inspect nahi kiya. Path {Path}",
                context.Request.ContentLength, context.Request.Path);
            return EnforcementResult.Unchanged;
        }

        context.Request.EnableBuffering();

        string json;
        using (var reader = new StreamReader(context.Request.Body, Encoding.UTF8, leaveOpen: true))
        {
            json = await reader.ReadToEndAsync(context.RequestAborted);
        }

        context.Request.Body.Position = 0;

        if (string.IsNullOrWhiteSpace(json))
        {
            return EnforcementResult.Unchanged;
        }

        JsonNode? root;
        try
        {
            root = JsonNode.Parse(json);
        }
        catch (JsonException)
        {
            // Kharab JSON — model binding khud 400 dega. Hum beech me nahi aayenge.
            return EnforcementResult.Unchanged;
        }

        if (root is null)
        {
            return EnforcementResult.Unchanged;
        }

        var outcome = EnforceOwnerId(root, tenant, isRoot: true, context, out var foreignOwnerId);

        if (outcome == EnforcementResult.Rejected)
        {
            logger.LogWarning(
                "Tenant isolation: user {UserId} ({Username}, owner {OwnerId}) ne request body me OwnerId={RequestedOwnerId} bheja. Path {Path}",
                tenant.UserId, tenant.Username, tenant.OwnerId, foreignOwnerId, context.Request.Path);
            return EnforcementResult.Rejected;
        }

        if (outcome == EnforcementResult.Unchanged)
        {
            return EnforcementResult.Unchanged;
        }

        var rewritten = Encoding.UTF8.GetBytes(root.ToJsonString());
        context.Request.Body = new MemoryStream(rewritten);
        context.Request.ContentLength = rewritten.Length;

        return EnforcementResult.Rewritten;
    }

    /// <summary>
    /// Root object par OwnerId hamesha set karta hai (na ho to add bhi kar deta hai, taaki
    /// client bhejna bhool jaye tab bhi sahi tenant lage). Nested objects me sirf tab
    /// badalta hai jab property pehle se maujood ho.
    /// </summary>
    private EnforcementResult EnforceOwnerId(
        JsonNode node,
        TenantContext tenant,
        bool isRoot,
        HttpContext context,
        out long foreignOwnerId)
    {
        foreignOwnerId = 0;
        var changed = false;

        switch (node)
        {
            case JsonObject obj:
            {
                var existingKey = obj
                    .Select(p => p.Key)
                    .FirstOrDefault(k => string.Equals(k, OwnerIdKey, StringComparison.OrdinalIgnoreCase));

                if (existingKey is not null)
                {
                    var current = ReadLong(obj[existingKey]);

                    if (current > 0 && current != tenant.OwnerId)
                    {
                        foreignOwnerId = current;
                        if (_options.StrictMode)
                        {
                            return EnforcementResult.Rejected;
                        }
                    }

                    if (current != tenant.OwnerId)
                    {
                        obj[existingKey] = tenant.OwnerId;
                        changed = true;
                    }
                }
                else if (isRoot)
                {
                    obj[OwnerIdKey] = tenant.OwnerId;
                    changed = true;
                }

                foreach (var property in obj.ToList())
                {
                    if (property.Value is null)
                    {
                        continue;
                    }

                    var childResult = EnforceOwnerId(property.Value, tenant, isRoot: false, context, out var childForeign);
                    if (childResult == EnforcementResult.Rejected)
                    {
                        foreignOwnerId = childForeign;
                        return EnforcementResult.Rejected;
                    }

                    if (childResult == EnforcementResult.Rewritten)
                    {
                        changed = true;
                    }
                }

                break;
            }

            case JsonArray array:
            {
                foreach (var item in array)
                {
                    if (item is null)
                    {
                        continue;
                    }

                    var childResult = EnforceOwnerId(item, tenant, isRoot: false, context, out var childForeign);
                    if (childResult == EnforcementResult.Rejected)
                    {
                        foreignOwnerId = childForeign;
                        return EnforcementResult.Rejected;
                    }

                    if (childResult == EnforcementResult.Rewritten)
                    {
                        changed = true;
                    }
                }

                break;
            }
        }

        return changed ? EnforcementResult.Rewritten : EnforcementResult.Unchanged;
    }

    private static long ReadLong(JsonNode? node)
    {
        if (node is not JsonValue value)
        {
            return 0;
        }

        if (value.TryGetValue<long>(out var asLong))
        {
            return asLong;
        }

        // Client ne string me bhej diya ho ("ownerId": "47") to bhi pakdo.
        return value.TryGetValue<string>(out var asString) && long.TryParse(asString, out var parsed)
            ? parsed
            : 0;
    }

    private static async Task WriteForbiddenAsync(HttpContext context, string field)
    {
        context.Response.StatusCode = StatusCodes.Status403Forbidden;
        context.Response.ContentType = "application/json";
        await context.Response.WriteAsJsonAsync(new
        {
            Success = false,
            Message = $"Access denied: {field} aapke account se match nahi karta.",
            Data = (object?)null
        });
    }

    private enum EnforcementResult
    {
        Unchanged,
        Rewritten,
        Rejected
    }
}

public sealed class TenantOptions
{
    public const string SectionName = "Tenancy";

    /// <summary>
    /// true  = mismatch par 403 (default — client hamesha apna hi ownerId bhejta hai,
    ///         isliye mismatch ka matlab bug ya attack hai).
    /// false = mismatch chup-chaap sudhar jaata hai, sirf warning log hoti hai.
    /// Security dono me barabar hai; farq sirf detection aur availability ka hai.
    /// </summary>
    public bool StrictMode { get; set; } = true;

    /// <summary>Isse bada JSON body inspect nahi hota (default 1 MB).</summary>
    public long MaxInspectedBodyBytes { get; set; } = 1_048_576;
}
