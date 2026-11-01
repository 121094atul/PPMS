using System.Text.Json;
using PPMS.Application.Features.Auth;

namespace PPMS.Application.Features.Owners;

public sealed class OwnerService(
    IOwnerRepository repository,
    IPasswordHasher passwordHasher,
    ITenantBackupWriter backupWriter) : IOwnerService
{
    public async Task<OwnerPageResult> GetPageAsync(string? search, string? status, string? sort, int pageNumber, int pageSize, CancellationToken cancellationToken = default)
    {
        pageNumber = Math.Max(1, pageNumber);
        pageSize = Math.Clamp(pageSize, 10, 100);
        var items = await repository.GetPageAsync(search, status, sort, pageNumber, pageSize, cancellationToken);
        var total = items.Count > 0 ? items[0].TotalCount : 0;

        // Aakhri page ke aage ka number (URL se) - khaali page ki jagah aakhri page dikhao.
        if (items.Count == 0 && pageNumber > 1)
        {
            var probe = await repository.GetPageAsync(search, status, sort, 1, pageSize, cancellationToken);
            total = probe.Count > 0 ? probe[0].TotalCount : 0;
            if (total > 0)
            {
                pageNumber = (total + pageSize - 1) / pageSize;
                items = await repository.GetPageAsync(search, status, sort, pageNumber, pageSize, cancellationToken);
            }
        }

        return new OwnerPageResult(items, total, pageNumber, pageSize);
    }

    public Task<OwnerStatusCountsDto> GetStatusCountsAsync(CancellationToken cancellationToken = default)
        => repository.GetStatusCountsAsync(cancellationToken);

    public Task SetArchivedAsync(long ownerId, bool archive, long? byUserId, CancellationToken cancellationToken = default)
        => repository.SetArchivedAsync(ownerId, archive, byUserId, cancellationToken);

    public async Task<(string FileName, byte[] Json)> ExportAsync(long ownerId, CancellationToken cancellationToken = default)
    {
        var tables = await repository.ExportAsync(ownerId, cancellationToken);
        var name = OwnerNameFrom(tables);
        return ($"tenant-{ownerId}-{DateTime.Now:yyyyMMdd-HHmmss}.json", backupWriter.ToJson(ownerId, name, tables));
    }

    public async Task<PurgeOwnerResult> PurgeAsync(long ownerId, string confirmName, long? byUserId, CancellationToken cancellationToken = default)
    {
        // Pehle sirf rok jaancho - warna har ruki koshish par bekaar backup file banti.
        await repository.CheckPurgeAsync(ownerId, confirmName ?? string.Empty, byUserId, cancellationToken);

        // Phir backup. File likhne me galti (folder nahi / permission) to yahin ruk jaata hai -
        // bina backup ke kabhi nahi mitta.
        var tables = await repository.ExportAsync(ownerId, cancellationToken);
        var name = OwnerNameFrom(tables);
        var file = await backupWriter.WriteAsync(ownerId, name, tables, cancellationToken);

        var deleted = await repository.PurgeAsync(ownerId, confirmName ?? string.Empty, byUserId, cancellationToken);
        return new PurgeOwnerResult(name, file, deleted);
    }

    /// <summary>Export ki pehli table PUMP.Owners hai - naam wahin se (alag query nahi).</summary>
    private static string OwnerNameFrom(IReadOnlyList<TenantExportTableDto> tables)
    {
        var owner = tables.FirstOrDefault(t => t.TableName == "PUMP.Owners");
        if (owner is null)
        {
            return string.Empty;
        }

        using var doc = JsonDocument.Parse(owner.Data);
        return doc.RootElement.GetArrayLength() > 0 && doc.RootElement[0].TryGetProperty("Name", out var n)
            ? n.GetString() ?? string.Empty
            : string.Empty;
    }

    public Task<IReadOnlyList<OwnerDto>> GetAllAsync(CancellationToken cancellationToken = default)
    {
        return repository.GetAllAsync(cancellationToken);
    }

    public Task<long> SaveAsync(SaveOwnerRequest request, CancellationToken cancellationToken = default)
    {
        var hash = passwordHasher.HashPassword(request.AdminPassword);
        return repository.SaveAsync(request.Name, request.AdminUsername, hash, cancellationToken);
    }

    public Task ToggleStatusAsync(long ownerId, CancellationToken cancellationToken = default)
    {
        return repository.ToggleStatusAsync(ownerId, cancellationToken);
    }

    public Task ExtendTrialAsync(long ownerId, DateTime newValidUpto, CancellationToken cancellationToken = default)
    {
        return repository.ExtendTrialAsync(ownerId, newValidUpto, cancellationToken);
    }

    public Task<IReadOnlyList<TenantUserDto>> GetUsersAsync(long ownerId, CancellationToken cancellationToken = default)
    {
        return repository.GetUsersAsync(ownerId, cancellationToken);
    }
}
