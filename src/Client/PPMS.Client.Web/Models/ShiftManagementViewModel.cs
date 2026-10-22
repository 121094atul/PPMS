using PPMS.Client.Web.Services;

namespace PPMS.Client.Web.Models;

public sealed class ShiftManagementViewModel
{
    public OpenShiftForm OpenShift { get; set; } = new();
    public CloseShiftForm CloseShift { get; set; } = new();
    public IReadOnlyList<ApiPumpDto> Pumps { get; set; } = Array.Empty<ApiPumpDto>();
    public IReadOnlyList<ApiNozzleDto> Nozzles { get; set; } = Array.Empty<ApiNozzleDto>();
    public IReadOnlyList<ApiEmployeeDto> Operators { get; set; } = Array.Empty<ApiEmployeeDto>();
    /// <summary>All active employees — used for nozzle-wise Attendant dropdowns (no login required)</summary>
    public IReadOnlyList<ApiEmployeeDto> AllEmployees { get; set; } = Array.Empty<ApiEmployeeDto>();
    public ApiPagedResponse<ApiShiftDto>? Shifts { get; set; }
    public string? Message { get; set; }
    /// <summary>Dashboard ke "Pending entries" se aaye ho — purani tareekh ki shift khul rahi hai.</summary>
    public bool IsBackdatedEntry { get; set; }

    // Pagination & Search
    public string? SearchTerm { get; set; }
    public DateTime? FromDate { get; set; }
    public DateTime? ToDate { get; set; }
    public int PageNumber { get; set; } = 1;
    public int PageSize { get; set; } = 50;

    /// <summary>
    /// Meter ki tooti hui kadi (Section R2) — page ke upar chetavni ke liye.
    /// Ye rokti kuch nahi; agar shift kholte waqt nazar chook gayi ho to yahan
    /// pakad me aa jaati hai.
    /// </summary>
    public IReadOnlyList<ApiMeterChainGap> MeterChainGaps { get; set; } = Array.Empty<ApiMeterChainGap>();
}

public sealed class CloseShiftForm
{
    public long Id { get; set; }
    public decimal ClosingCash { get; set; }
    public string? Notes { get; set; }
    public List<ShiftNozzleCloseReadingForm> NozzleReadings { get; set; } = new();

    /// <summary>
    /// Shift band karte waqt hi tank ki dip (Section AB). Khaali chhodna theek
    /// hai — sirf jis tank ka Actual Stock bhara ho, wahi save hota hai.
    /// </summary>
    public List<ShiftClosingDipForm> Dips { get; set; } = new();
}

public sealed class ShiftClosingDipForm
{
    public long TankId { get; set; }
    public decimal? DipCm { get; set; }
    public decimal? ActualStock { get; set; }
}

public sealed class OpenShiftForm
{
    public long OwnerId { get; set; }
    public long PumpId { get; set; } = 1;
    /// <summary>
    /// Kaun is shift ka zimmedar hai — ab EMPLOYEE se (Section K). Pehle ye
    /// OperatorUserId tha, isliye dropdown me sirf wahi log dikhte the jinka
    /// login bana ho; bina-login wala aadmi (chowkidar, helper) in-charge ban
    /// hi nahi sakta tha, jabki wahi aadmi nozzle par attendant ban sakta tha.
    /// Khaali chhodna theek hai — chhote pump par malik khud sab dekhta hai.
    /// </summary>
    public long? OperatorEmployeeId { get; set; }
    public DateOnly ShiftDate { get; set; } = DateOnly.FromDateTime(DateTime.Today);
    public string ShiftCode { get; set; } = "A";
    public decimal OpeningCash { get; set; }
    public string? Notes { get; set; }
    public List<ShiftNozzleOpenReadingForm> NozzleReadings { get; set; } = new();

    /// <summary>
    /// "Meter badla gaya / farak manzoor hai" wala checkbox (Section R).
    ///
    /// Normally opening reading us nozzle ki pichli shift ke closing se milni
    /// chahiye. Na mile to API rok deti hai aur bata deti hai kitna farak hai.
    /// Meter sach me badla ho ya rollover hua ho — wo jaayaz hai — tab user ye
    /// tick karke aage badh sakta hai. Har baar khud se false ho jaata hai,
    /// taaki agli shift par rok phir se lage.
    /// </summary>
    public bool AllowMeterGap { get; set; }
}

public sealed class ShiftNozzleOpenReadingForm
{
    public long NozzleId { get; set; }
    public long ProductId { get; set; }

    /// <summary>
    /// Is nozzle par kaun aadmi hai. Form me ye khaana pehle se tha lekin kahin
    /// SAVE hi nahi hota tha — user chunta, submit karta, aur chunav chupchaap
    /// gayab ho jaata tha.
    /// </summary>
    public long? AttendantEmployeeId { get; set; }

    /// <summary>Shift shuru me is aadmi ko diya gaya chhutta.</summary>
    public decimal? FloatGiven { get; set; }
    public string NozzleCode { get; set; } = string.Empty;
    public string ProductName { get; set; } = string.Empty;
    public decimal OpeningReading { get; set; }
}

public sealed class ShiftNozzleCloseReadingForm
{
    public long NozzleId { get; set; }
    public string NozzleCode { get; set; } = string.Empty;
    public string ProductName { get; set; } = string.Empty;
    public decimal OpeningReading { get; set; }
    public decimal Rate { get; set; }
    public decimal ClosingReading { get; set; }
    public decimal TestingLoss { get; set; }

    /// <summary>Tel (litre) hai to testing ka khaana; gas (CNG, kg) ki testing nahi hoti (Section AL).</summary>
    public bool IsLiquid { get; set; } = true;
}
