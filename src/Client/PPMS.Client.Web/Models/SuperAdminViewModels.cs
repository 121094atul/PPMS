using PPMS.Client.Web.Services;

namespace PPMS.Client.Web.Models;

/// <summary>
/// Super Admin ki tenant list (Section AX) - page, search aur filter server par. Pehle saare
/// tenant ek saath aate the aur browser 25-25 ke page banata tha.
/// </summary>
public sealed class TenantListViewModel
{
    public IReadOnlyList<ApiOwnerPageRowDto> Items { get; set; } = Array.Empty<ApiOwnerPageRowDto>();
    public ApiOwnerStatusCountsDto? Counts { get; set; }
    public IReadOnlyList<ApiSubscriptionRequestDto> Requests { get; set; } = Array.Empty<ApiSubscriptionRequestDto>();

    public string? Search { get; set; }
    public string Status { get; set; } = "ALL";
    public string Sort { get; set; } = "NEWEST";
    public int PageNumber { get; set; } = 1;
    public int PageSize { get; set; } = 25;
    public int TotalCount { get; set; }

    public int TotalPages => TotalCount == 0 ? 1 : (TotalCount + PageSize - 1) / PageSize;
    public int FirstRow => TotalCount == 0 ? 0 : (PageNumber - 1) * PageSize + 1;
    public int LastRow => Math.Min(PageNumber * PageSize, TotalCount);
    public bool IsArchivedView => Status == "ARCHIVED";

    /// <summary>Filter chip: (status, naam, ginti).</summary>
    public IEnumerable<(string Key, string Label, int? Count)> StatusChips()
    {
        yield return ("ALL", "All", Counts?.AllCount);
        yield return ("ACTIVE", "Active", Counts?.Active);
        yield return ("TRIAL", "Trial", Counts?.Trial);
        yield return ("EXPIRING", "Ends in 7 days", Counts?.Expiring);
        yield return ("EXPIRED", "Expired", Counts?.Expired);
        yield return ("IDLE", "No entry for 7 days", Counts?.Idle);
        yield return ("SUSPENDED", "Suspended", Counts?.Suspended);
        yield return ("ARCHIVED", "Removed", Counts?.Archived);
    }

    public static readonly string[] SortKeys = ["NEWEST", "OLDEST", "NAME", "VALIDUPTO", "LASTENTRY"];
}
