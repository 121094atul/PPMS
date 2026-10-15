namespace PPMS.Application.Interfaces;

/// <summary>
/// Kuch endpoints sirf ek id lete hain — jaise /api/shifts/{id}/summary ya
/// /api/sales/{id}/receipt. Un me ownerId hai hi nahi, isliye koi bhi logged-in
/// user doosre owner ki shift ya bill nikal sakta tha.
///
/// Ye guard poochta hai: "kya ye record sach me is owner ka hai?" — service call
/// karne se PEHLE.
/// </summary>
public interface ITenantGuard
{
    /// <param name="entity">
    /// Shift | Sale | Product | Pump | Role | Party | Tank | Nozzle | Purchase | Vendor | Employee
    /// </param>
    Task<bool> OwnsAsync(long ownerId, string entity, long entityId, CancellationToken cancellationToken = default);
}

public static class TenantEntities
{
    public const string Shift = "Shift";
    public const string Sale = "Sale";
    public const string Product = "Product";
    public const string Pump = "Pump";
    public const string Role = "Role";
    public const string Party = "Party";
    public const string Tank = "Tank";
    public const string Nozzle = "Nozzle";
    public const string Purchase = "Purchase";
    public const string Vendor = "Vendor";
    public const string Employee = "Employee";
}
