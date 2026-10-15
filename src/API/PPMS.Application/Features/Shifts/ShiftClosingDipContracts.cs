namespace PPMS.Application.Features.Shifts;

/// <summary>
/// Close Shift form me tank ki dip (Section AB).
///
/// Pehle dip ek alag page (Dip Testing) par daalni padti thi — aur wahi sabse
/// badi galti ki jagah thi: shift band hone se PEHLE dip daal di (09 Sep), galat
/// tareekh, galat tank. Ab shift band karte hi usi form me dip jaati hai —
/// tareekh aur shift apne aap wahi.
///
/// NOTE (CLAUDE.md niyam 5): param theek `sp_Shift_ClosingDipList` ke column ke
/// kram, naam aur type se milte hain.
/// </summary>
public sealed record ShiftClosingDipRow(
    long TankId,
    string TankName,
    string ProductName,
    /// <summary>Is shift ki apni bikri CHHOD kar book stock. Form isme se
    /// likhi jaa rahi bikri ghata kar turant farak dikhata hai.</summary>
    decimal BookExcludingShift,
    /// <summary>Is tank se judi nozzle ki id, comma se alag ("2,3,4").</summary>
    string NozzleIds,
    long? DipId,
    decimal? DipCm,
    decimal? ActualStock);

public sealed record ShiftClosingDipInput(long TankId, decimal? DipCm, decimal ActualStock);

public sealed record SaveShiftClosingDipsRequest(IReadOnlyList<ShiftClosingDipInput> Dips);

/// <summary>`sp_Shift_SaveClosingDips` ka jawab — kram aur type SP jaisa.</summary>
public sealed record ShiftClosingDipSaved(
    long TankId,
    string TankName,
    decimal ExpectedStock,
    decimal ActualStock,
    decimal Variance);
