using PPMS.Client.Web.Services;

namespace PPMS.Client.Web.Models;

public sealed class DipTestingViewModel
{
    public DipReadingForm DipReadingForm { get; set; } = new();
    public TestingLossForm TestingLossForm { get; set; } = new();
    public IReadOnlyList<ApiPumpDto> Pumps { get; set; } = Array.Empty<ApiPumpDto>();
    public IReadOnlyList<ApiTankDto> Tanks { get; set; } = Array.Empty<ApiTankDto>();
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

    public ApiPagedResponse<ApiDipReadingDto>? DipReadings { get; set; }
    public ApiPagedResponse<ApiTestingLossDto>? TestingLosses { get; set; }
    public DateTime? FromDate { get; set; }
    public DateTime? ToDate { get; set; }
    public int PageNumber { get; set; } = 1;
    public int PageSize { get; set; } = 50;
    public string? Message { get; set; }
}

public sealed class DipReadingForm
{
    public long OwnerId { get; set; }
    public long PumpId { get; set; }
    public long TankId { get; set; }
    public DateTime ReadingDate { get; set; } = DateTime.Today;
    public long? ShiftId { get; set; }
    public decimal DipCm { get; set; }
    public decimal? WaterDipCm { get; set; }
    public decimal? Density { get; set; }
    public decimal? Temperature { get; set; }
    public decimal ExpectedStock { get; set; }
    public decimal ActualStock { get; set; }
}

public sealed class TestingLossForm
{
    public long OwnerId { get; set; }
    public long PumpId { get; set; }
    public long TankId { get; set; }
    public DateTime LossDate { get; set; } = DateTime.Today;
    public long? ShiftId { get; set; }
    public string LossType { get; set; } = "Testing";
    public decimal Quantity { get; set; }
    public string? Notes { get; set; }
}
