namespace PPMS.Client.Web.Models;

using PPMS.Client.Web.Services;

/// <summary>
/// "Nozzle Cash" screen. Pump par har nozzle par alag aadmi hota hai — accountant
/// shift shuru me chhutta deta hai aur baad me har aadmi se alag cash leta hai.
/// Poore din ka cash raat me ek saath lena ho to bhi yahin se hota hai.
/// </summary>
public sealed class NozzleCashViewModel
{
    public long OwnerId { get; set; }
    public long PumpId { get; set; }
    public IReadOnlyList<ApiPumpDto> Pumps { get; set; } = Array.Empty<ApiPumpDto>();
    public IReadOnlyList<ApiEmployeeDto> Employees { get; set; } = Array.Empty<ApiEmployeeDto>();

    /// <summary>Jis shift ka hisaab khula hua hai (0 = koi nahi chuna).</summary>
    public long SelectedShiftId { get; set; }

    public IReadOnlyList<ApiShiftDto> Shifts { get; set; } = Array.Empty<ApiShiftDto>();
    public IReadOnlyList<ApiNozzleCashDto> ShiftRows { get; set; } = Array.Empty<ApiNozzleCashDto>();

    /// <summary>Jitna cash abhi tak nahi liya — chahe shift kab ki bhi ho.</summary>
    public IReadOnlyList<ApiPendingCashDto> Pending { get; set; } = Array.Empty<ApiPendingCashDto>();

    public string? Message { get; set; }
    public bool IsError { get; set; }

    public decimal PendingTotal => Pending.Sum(x => x.ExpectedCash);
}

/// <summary>Aadmi-wise report — "is mahine kis aadmi ka kitna kam pada".</summary>
public sealed class AttendantCashReportViewModel
{
    public long PumpId { get; set; }
    public IReadOnlyList<ApiPumpDto> Pumps { get; set; } = Array.Empty<ApiPumpDto>();
    public DateOnly FromDate { get; set; }
    public DateOnly ToDate { get; set; }
    public IReadOnlyList<ApiAttendantCashDto> Rows { get; set; } = Array.Empty<ApiAttendantCashDto>();
}
