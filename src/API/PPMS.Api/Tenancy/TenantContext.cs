using System.Security.Claims;
using PPMS.Application.Interfaces;

namespace PPMS.Api.Tenancy;

/// <summary>
/// Scoped implementation — har request ke liye ek. TenantIsolationMiddleware ise
/// JWT claims se bharta hai.
/// </summary>
public sealed class TenantContext : ITenantContext
{
    public long OwnerId { get; private set; }
    public long UserId { get; private set; }
    public string? Username { get; private set; }
    public long RoleId { get; private set; }
    public bool IsSuperAdmin { get; private set; }
    public bool IsResolved { get; private set; }

    public void PopulateFrom(ClaimsPrincipal? user)
    {
        if (user?.Identity?.IsAuthenticated != true)
        {
            return;
        }

        IsSuperAdmin = string.Equals(
            user.FindFirstValue(PpmsClaims.IsSuperAdmin),
            "true",
            StringComparison.OrdinalIgnoreCase);

        Username = user.FindFirstValue(ClaimTypes.Name);

        if (long.TryParse(user.FindFirstValue(ClaimTypes.NameIdentifier), out var userId))
        {
            UserId = userId;
        }

        if (long.TryParse(user.FindFirstValue(PpmsClaims.RoleId), out var roleId))
        {
            RoleId = roleId;
        }

        // Yahi wo line hai jispar poori tenant isolation tiki hai:
        // OwnerId sirf token se aata hai. Query string ya request body se kabhi nahi.
        if (long.TryParse(user.FindFirstValue(PpmsClaims.OwnerId), out var ownerId) && ownerId > 0)
        {
            OwnerId = ownerId;
            IsResolved = true;
        }
    }
}

public static class PpmsClaims
{
    public const string OwnerId = "owner_id";
    public const string RoleId = "role_id";
    public const string IsSuperAdmin = "is_super_admin";
    public const string FullName = "full_name";
}
