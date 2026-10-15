using PPMS.Client.Web.Services;

namespace PPMS.Client.Web.Models;

public sealed class PurchaseManagementViewModel
{
    public PurchaseForm Form { get; set; } = new();
    public IReadOnlyList<ApiPumpDto> Pumps { get; set; } = Array.Empty<ApiPumpDto>();
    public IReadOnlyList<ApiVendorDto> Vendors { get; set; } = Array.Empty<ApiVendorDto>();
    public IReadOnlyList<ApiProductDto> Products { get; set; } = Array.Empty<ApiProductDto>();
    public IReadOnlyList<ApiTankDto> Tanks { get; set; } = Array.Empty<ApiTankDto>();
    public ApiPagedResponse<ApiPurchaseDto>? Purchases { get; set; }
    public DateTime? FromDate { get; set; }
    public DateTime? ToDate { get; set; }
    public string? SearchTerm { get; set; }
    public int PageNumber { get; set; } = 1;
    public int PageSize { get; set; } = 50;
    public string? Message { get; set; }
}

public sealed class PurchaseForm
{
    public long Id { get; set; }
    public long OwnerId { get; set; }
    public long PumpId { get; set; }
    public long VendorId { get; set; }
    public string InvoiceNo { get; set; } = string.Empty;
    public DateOnly InvoiceDate { get; set; } = DateOnly.FromDateTime(DateTime.Today);
    public string? VehicleNo { get; set; }
    public string? DriverName { get; set; }
    public string? Notes { get; set; }
    public List<PurchaseLineForm> Items { get; set; } = new() { new PurchaseLineForm() };
}

public sealed class PurchaseLineForm
{
    public long ProductId { get; set; }
    public long? TankId { get; set; }

    /// <summary>
    /// Khaali (0) se shuru. Pehle ye 1 tha aur rate bhi bhara aata tha - log
    /// doosri line jod kar pehli bhool jaate, aur bill me "1 litre diesel" ki
    /// bhatki hui line save ho jaati thi (UAT ke bill 5 me yahi hua).
    /// </summary>
    public decimal Quantity { get; set; }

    /// <summary>
    /// Is product ki BILL wali rakam - VAT aur recovery mila kar (Section AE).
    /// Rate ab user nahi bharta; wo isi se nikalta hai.
    /// </summary>
    public decimal Amount { get; set; }

    public decimal Rate { get; set; }
}

public sealed class StockReconciliationViewModel
{
    public StockReconciliationForm Form { get; set; } = new();
    public IReadOnlyList<ApiPumpDto> Pumps { get; set; } = Array.Empty<ApiPumpDto>();
    public IReadOnlyList<ApiTankDto> Tanks { get; set; } = Array.Empty<ApiTankDto>();
    public ApiPagedResponse<ApiStockReconciliationDto>? Entries { get; set; }
    public DateTime? FromDate { get; set; }
    public DateTime? ToDate { get; set; }
    public string? SearchTerm { get; set; }
    public int PageNumber { get; set; } = 1;
    public int PageSize { get; set; } = 50;
    public string? Message { get; set; }
}

public sealed class StockReconciliationForm
{
    public long OwnerId { get; set; }
    public long PumpId { get; set; }
    public long TankId { get; set; }
    public DateOnly ReconciliationDate { get; set; } = DateOnly.FromDateTime(DateTime.Today);
    public decimal BookStock { get; set; }
    public decimal PhysicalStock { get; set; }
    public string? Reason { get; set; }
}

public sealed class VendorManagementViewModel
{
    public VendorForm Form { get; set; } = new();
    public IReadOnlyList<ApiPumpDto> Pumps { get; set; } = Array.Empty<ApiPumpDto>();
    public IReadOnlyList<ApiVendorDto> Vendors { get; set; } = Array.Empty<ApiVendorDto>();
    public string? SearchTerm { get; set; }
    public string? Message { get; set; }
}

public sealed class VendorForm
{
    public long Id { get; set; }
    public long OwnerId { get; set; }
    public long PumpId { get; set; }
    public string VendorName { get; set; } = string.Empty;
    public string? ContactNo { get; set; }
    public string? GSTIN { get; set; }
    public string? Address { get; set; }
    public bool IsActive { get; set; } = true;
}
