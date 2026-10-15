namespace PPMS.Application.Features.Shifts;

public sealed record OpenShiftRequest(
    long OwnerId,
    long PumpId,
    // ShiftHeaders.OperatorUserId DB me nullable hai. Naye pump par koi employee
    // hota hi nahi, isliye in-charge chunna zaroori nahi. Pehle ye non-nullable tha
    // aur 0 bhejne par FK toot jaati thi (500) — yaani pehli shift kabhi khulti hi
    // nahi thi.
    long? OperatorUserId,
    DateOnly ShiftDate,
    string ShiftCode,
    decimal OpeningCash,
    string? Notes,
    IReadOnlyList<ShiftNozzleOpenReadingRequest> NozzleReadings,
    // Shift ka in-charge (Section K). Ye asli field hai; OperatorUserId isi
    // employee ke record se SP khud bhar leta hai. Sabse aakhir me hai kyunki
    // iska default hai — purane caller bina ise bheje bhi chalte rahenge.
    long? OperatorEmployeeId = null,
    // Meter ki kadi (Section R). Normally shift kholte waqt opening reading us
    // nozzle ki pichli shift ke closing se milni chahiye; na mile to SP rok deta
    // hai (THROW 50132). Meter badla ho, rollover hua ho, ya user ne farak dekh
    // kar bhi aage badhne ka faisla kiya ho — tab client ye true bhejta hai.
    bool AllowMeterGap = false
);

/// <summary>
/// Shift shuru hote waqt har nozzle par: kaun aadmi hai aur use kitna chhutta diya.
/// Dono optional - jo pump nozzle-wise cash nahi chalata, uske liye kuch nahi badla.
/// </summary>
public sealed record ShiftNozzleOpenReadingRequest(
    long NozzleId,
    long ProductId,
    decimal OpeningReading
,
    long? EmployeeId = null,
    decimal? FloatGiven = null);
