namespace PPMS.Application.Features.Owners;

/// <summary>
/// Super Admin ki tenant list ka ek row (Section AX). NOTE: PUMP.sp_Owner_GetPage ke SELECT se
/// bilkul isi kram / type me - Dapper record constructor se banata hai (CLAUDE.md niyam 5).
/// </summary>
public sealed record OwnerPageRowDto(
    long Id,
    string Name,
    bool IsActive,
    DateTime CreatedOn,
    DateTime? ValidUpto,
    string? ContactName,
    string? ContactNo,
    string? Email,
    string? City,
    string? StateCode,
    string? GSTIN,
    string? PlanCode,
    bool IsTrial,
    int PumpCount,
    int UserCount,
    int? DaysLeft,
    DateTime? LastLoginOn,
    DateTime? LastActivityOn,
    decimal SalesThisMonth,
    bool IsArchived,
    DateTime? ArchivedOn,
    int TotalCount);

public sealed record OwnerPageResult(IReadOnlyList<OwnerPageRowDto> Items, int TotalCount, int PageNumber, int PageSize);

/// <summary>PUMP.sp_Owner_StatusCounts - har filter ki ginti.</summary>
public sealed record OwnerStatusCountsDto(
    int AllCount, int Active, int Suspended, int Trial, int Expired, int Expiring, int Idle, int Archived);

/// <summary>PUMP.sp_Owner_Export - ek table ka saara data (JSON array).</summary>
public sealed record TenantExportTableDto(string TableName, int RowsCount, string Data);

/// <summary>PUMP.sp_Owner_Purge - kis table se kitni row miti.</summary>
public sealed record TenantPurgeRowDto(string TableName, int RowsDeleted);

public sealed record ArchiveOwnerRequest(bool Archive);

public sealed record PurgeOwnerRequest(string ConfirmName);

public sealed record PurgeOwnerResult(string OwnerName, string BackupFile, IReadOnlyList<TenantPurgeRowDto> Deleted);

/// <summary>
/// Mitane se pehle tenant ka data file me. Infrastructure me - file ka folder config se
/// (TenantBackup:Path), Application layer IO / config se nahi judti.
/// </summary>
public interface ITenantBackupWriter
{
    /// <returns>Likhi gayi file ka poora path.</returns>
    Task<string> WriteAsync(long ownerId, string ownerName, IReadOnlyList<TenantExportTableDto> tables, CancellationToken cancellationToken = default);

    /// <summary>Wahi JSON jo file me jaata hai - Super Admin ke "data download" ke liye.</summary>
    byte[] ToJson(long ownerId, string ownerName, IReadOnlyList<TenantExportTableDto> tables);
}
