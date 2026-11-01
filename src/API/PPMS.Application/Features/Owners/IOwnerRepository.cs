namespace PPMS.Application.Features.Owners;

public interface IOwnerRepository
{
    Task<IReadOnlyList<OwnerDto>> GetAllAsync(CancellationToken cancellationToken = default);
    Task<long> SaveAsync(string name, string adminUsername, string adminPasswordHash, CancellationToken cancellationToken = default);
    Task ToggleStatusAsync(long ownerId, CancellationToken cancellationToken = default);
    Task ExtendTrialAsync(long ownerId, DateTime newValidUpto, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<TenantUserDto>> GetUsersAsync(long ownerId, CancellationToken cancellationToken = default);

    // Section AX
    Task<IReadOnlyList<OwnerPageRowDto>> GetPageAsync(string? search, string? status, string? sort, int pageNumber, int pageSize, CancellationToken cancellationToken = default);
    Task<OwnerStatusCountsDto> GetStatusCountsAsync(CancellationToken cancellationToken = default);
    Task SetArchivedAsync(long ownerId, bool archive, long? byUserId, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<TenantExportTableDto>> ExportAsync(long ownerId, CancellationToken cancellationToken = default);
    /// <summary>Sirf rok jaancho (hataya hua? naam? 15 din?) - THROW kare to backup file bhi na bane.</summary>
    Task CheckPurgeAsync(long ownerId, string confirmName, long? byUserId, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<TenantPurgeRowDto>> PurgeAsync(long ownerId, string confirmName, long? byUserId, CancellationToken cancellationToken = default);
}
