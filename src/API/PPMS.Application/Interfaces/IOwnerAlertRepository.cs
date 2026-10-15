namespace PPMS.Application.Interfaces;

/// <summary>Owner ka alert number aur uski marzi — sab OwnerId ke daayre me.</summary>
public interface IOwnerAlertRepository
{
    Task<OwnerAlertTarget?> GetTargetAsync(long ownerId, string alertKey, CancellationToken cancellationToken = default);

    Task<IReadOnlyList<OwnerAlertSetting>> ListAsync(long ownerId, CancellationToken cancellationToken = default);

    Task SaveAsync(long ownerId, string alertKey, bool isEnabled, CancellationToken cancellationToken = default);

    Task SaveMobileAsync(long ownerId, string? mobile, CancellationToken cancellationToken = default);
}

/// <summary>
/// sp_Notification_GetOwnerTarget ka nateeja. CLAUDE.md niyam 5 — SP ka har
/// column yahan param hona chahiye, warna Dapper record bana hi nahi paata.
/// </summary>
public sealed record OwnerAlertTarget(string? Mobile, bool IsEnabled, string OwnerName);

/// <summary>Settings screen ki ek line (sp_OwnerAlert_List).</summary>
public sealed record OwnerAlertSetting(string AlertKey, string Title, string Description, bool IsEnabled);

/// <summary>Ek alert ka switch on/off.</summary>
public sealed record SaveOwnerAlertRequest(string AlertKey, bool IsEnabled);

/// <summary>Alert kis number par jayein.</summary>
public sealed record SaveOwnerAlertMobileRequest(string? Mobile);
