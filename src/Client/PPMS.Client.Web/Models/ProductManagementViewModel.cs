using PPMS.Client.Web.Services;

namespace PPMS.Client.Web.Models;

public sealed class ProductManagementViewModel
{
    public ProductForm Form { get; set; } = new();
    public IReadOnlyList<ApiPumpDto> Pumps { get; set; } = Array.Empty<ApiPumpDto>();
    public IReadOnlyList<ApiProductDto> Products { get; set; } = Array.Empty<ApiProductDto>();
    public string? Message { get; set; }
}

public sealed class ProductForm
{
    public long? Id { get; set; }
    public long OwnerId { get; set; }
    public long PumpId { get; set; }
    public string Name { get; set; } = string.Empty;
    public string Category { get; set; } = "Petrol";
    public string Unit { get; set; } = "Litre";
    public decimal CurrentRate { get; set; }
    public string? HSNCode { get; set; }
    public decimal CGSTRate { get; set; }
    public decimal SGSTRate { get; set; }
}
