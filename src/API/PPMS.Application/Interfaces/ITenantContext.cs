namespace PPMS.Application.Interfaces;

/// <summary>
/// Current request ka tenant. Ye JWT claims se bharta hai — client ke bheje hue
/// ownerId se NAHI. Multi-tenant isolation ka single source of truth yahi hai.
/// </summary>
public interface ITenantContext
{
    /// <summary>Logged-in user ka owner. 0 matlab tenant resolve nahi hua.</summary>
    long OwnerId { get; }

    long UserId { get; }

    string? Username { get; }

    long RoleId { get; }

    bool IsSuperAdmin { get; }

    /// <summary>OwnerId set hai ya nahi. false ho to request aage nahi badhni chahiye.</summary>
    bool IsResolved { get; }
}
