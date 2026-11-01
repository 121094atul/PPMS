namespace PPMS.Application.Features.Owners;

public interface IOwnerService
{
    Task<IReadOnlyList<OwnerDto>> GetAllAsync(CancellationToken cancellationToken = default);
    Task<long> SaveAsync(SaveOwnerRequest request, CancellationToken cancellationToken = default);
    Task ToggleStatusAsync(long ownerId, CancellationToken cancellationToken = default);
    Task ExtendTrialAsync(long ownerId, DateTime newValidUpto, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<TenantUserDto>> GetUsersAsync(long ownerId, CancellationToken cancellationToken = default);

    // Section AX
    Task<OwnerPageResult> GetPageAsync(string? search, string? status, string? sort, int pageNumber, int pageSize, CancellationToken cancellationToken = default);
    Task<OwnerStatusCountsDto> GetStatusCountsAsync(CancellationToken cancellationToken = default);
    Task SetArchivedAsync(long ownerId, bool archive, long? byUserId, CancellationToken cancellationToken = default);

    /// <returns>(file ka naam, JSON) - Super Admin download kar sake.</returns>
    Task<(string FileName, byte[] Json)> ExportAsync(long ownerId, CancellationToken cancellationToken = default);

    /// <summary>Pehle data file me (backup), PHIR mitao. File na bane to kuch nahi mitta.</summary>
    Task<PurgeOwnerResult> PurgeAsync(long ownerId, string confirmName, long? byUserId, CancellationToken cancellationToken = default);
}
