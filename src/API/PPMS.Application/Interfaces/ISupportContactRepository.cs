namespace PPMS.Application.Interfaces;

/// <summary>
/// Support ke number (Section AR) - Super Admin daalta hai, Login page / Manual / sandesh me dikhte hain.
/// NOTE (CLAUDE.md niyam 5): param theek `sp_SupportContacts_Get` ke column ke kram se.
/// </summary>
public sealed record SupportContacts(string? Phone1, string? Phone2, string? Phone3)
{
    /// <summary>Jo number bhare hain, kram se.</summary>
    public IReadOnlyList<string> Numbers =>
        new[] { Phone1, Phone2, Phone3 }.Where(p => !string.IsNullOrWhiteSpace(p)).Select(p => p!).ToList();

    /// <summary>Sandesh me likhne ke liye: "6394389973 / 9876543210". Koi na ho to null.</summary>
    public string? Display => Numbers.Count == 0 ? null : string.Join(" / ", Numbers);
}

public sealed record SaveSupportContactsRequest(string? Phone1, string? Phone2, string? Phone3);

public interface ISupportContactRepository
{
    Task<SupportContacts> GetAsync(CancellationToken cancellationToken = default);
    Task<SupportContacts> SaveAsync(string phone1, string? phone2, string? phone3, long? userId, CancellationToken cancellationToken = default);
}
