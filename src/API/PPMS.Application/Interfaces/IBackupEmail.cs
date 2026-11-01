namespace PPMS.Application.Interfaces;

/// <summary>
/// Roz ka backup email par (Section BA). Shared server par BACKUP DATABASE ki ijaazat nahi - isliye
/// app khud saara data padh ke zip banati hai aur Gmail se bhejti hai. Setting DB me (AppSettings).
/// </summary>
public interface IBackupEmailRepository
{
    Task<BackupEmailSettings> GetAsync(CancellationToken cancellationToken = default);

    Task<BackupEmailSettings> SaveAsync(bool enabled, string? emailTo, int hour, long? byUserId, CancellationToken cancellationToken = default);

    /// <summary>Aaj ka backup yahi copy bheje? (ek din me ek; fail ho to ghante bhar baad.) force = "abhi bhejiye".</summary>
    Task<bool> ClaimAsync(DateOnly today, bool force, CancellationToken cancellationToken = default);

    Task SetResultAsync(bool ok, DateOnly today, string status, CancellationToken cancellationToken = default);
}

/// <summary>PUMP.sp_BackupEmail_Get - isi kram / type me (CLAUDE.md niyam 5).</summary>
public sealed record BackupEmailSettings(
    bool Enabled, string? EmailTo, int Hour, DateTime? LastSuccessDate, DateTime? LastAttemptOn, string? LastStatus);

public sealed record SaveBackupEmailRequest(bool Enabled, string? EmailTo, int Hour);

public sealed record BackupRunResult(bool Ok, string Status);

/// <summary>Backup banao aur bhejo - background service aur "abhi bhejiye" button dono yahi chalate hain.</summary>
public interface IBackupEmailRunner
{
    /// <param name="force">true = tareekh / ghanta / chalu-band ki rok nahi (Super Admin ka button).</param>
    /// <returns>null = aaj ka pehle hi gaya / abhi samay nahi / doosri copy bhej rahi hai.</returns>
    Task<BackupRunResult?> RunAsync(bool force, CancellationToken cancellationToken = default);
}
