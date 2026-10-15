using PPMS.Client.Web.Services;

namespace PPMS.Client.Web.Models;

public sealed class SalesManagementViewModel
{
    public SalesForm Form { get; set; } = new();
    public IReadOnlyList<ApiPumpDto> Pumps { get; set; } = Array.Empty<ApiPumpDto>();
    public IReadOnlyList<ApiNozzleDto> Nozzles { get; set; } = Array.Empty<ApiNozzleDto>();
    public IReadOnlyList<ApiShiftDto> OpenShifts { get; set; } = Array.Empty<ApiShiftDto>();

    /// <summary>
    /// Jin shift se ye entry jod sakte hain — khuli shift pehle, phir haal me
    /// band hui shift.
    ///
    /// Pehle sirf <see cref="OpenShifts"/> dikhti thi, isliye kisi purane (band
    /// ho chuke) din ka kharcha, cash ya dip us din ki shift se jud hi nahi
    /// sakta tha — entry ban jaati thi par ShiftId NULL reh jaata tha.
    /// </summary>
    public IReadOnlyList<ApiShiftDto> LinkableShifts { get; set; } = Array.Empty<ApiShiftDto>();

    public IReadOnlyList<ApiProductDto> Products { get; set; } = Array.Empty<ApiProductDto>();
    public IReadOnlyList<ApiPartyDto> Parties { get; set; } = Array.Empty<ApiPartyDto>();
    public ApiPagedResponse<ApiSaleDto>? Sales { get; set; }
    public ApiReceiptDto? LatestReceipt { get; set; }
    public string? Message { get; set; }

    // Pagination & Search
    public string? SearchTerm { get; set; }
    public DateTime? FromDate { get; set; }
    public DateTime? ToDate { get; set; }
    public int PageNumber { get; set; } = 1;
    public int PageSize { get; set; } = 50;
}

public sealed class SalesForm
{
    public long OwnerId { get; set; }
    public long PumpId { get; set; }
    public long ShiftId { get; set; }
    public string PaymentMode { get; set; } = "Cash";
    public long? PartyId { get; set; }
    public string? VehicleNo { get; set; }
    public string? CustomerName { get; set; }
    public string? AttendantName { get; set; }
    /// <summary>Bill ki tareekh — purani entry karne ke liye badli ja sakti hai.</summary>
    public DateTime BillDateTime { get; set; } = DateTime.Now;
    public List<SalesLineForm> Items { get; set; } = new() { new SalesLineForm() };
}

public sealed class SalesLineForm
{
    public long ProductId { get; set; }
    public string? NozzleNo { get; set; }
    public decimal Quantity { get; set; } = 1;
    public decimal Rate { get; set; }
}
