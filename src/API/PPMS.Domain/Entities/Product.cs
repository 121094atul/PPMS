using PPMS.Domain.Enums;

namespace PPMS.Domain.Entities;

public sealed class Product : BaseEntity
{
    public string Name { get; set; } = string.Empty;
    public ProductCategory Category { get; set; }
    public string Unit { get; set; } = "Litre";
    public decimal CurrentRate { get; set; }
}
