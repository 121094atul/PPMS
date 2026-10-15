namespace PPMS.Application.Features.Shifts;

/// <summary>
/// Meter ki tooti hui kadi (Section R2).
///
/// Ek nozzle ki shift tareekh ke kram me lagayein to har agli shift ka opening
/// reading pichli shift ke closing se milna chahiye. Na mile to us beech me
/// fuel ka hisaab hi nahi banta — us din ka sale, stock aur cash teeno galat
/// ho jaate hain.
///
/// Aisa aksar tab hota hai jab purani tareekh ki shift baad me daali jaati hai
/// ("Forgot a day? Enter it later"), ya koi bhari hui opening reading haath se
/// badal deta hai.
///
/// NOTE (CLAUDE.md niyam 5): iske param sp_Shift_MeterChainCheck ke column ke
/// theek us kram me hain. SP me column badle to yahan bhi badalna hoga, warna
/// Dapper record bana hi nahi paayega.
/// </summary>
public sealed record MeterChainGapDto(
    long NozzleId,
    string NozzleCode,
    long PumpId,
    long PrevShiftId,
    DateOnly PrevDate,
    decimal PrevClosing,
    long ShiftId,
    DateOnly ShiftDate,
    string ShiftCode,
    decimal OpeningReading,
    // Aage ka opening minus pichla closing. Plus ka matlab reading aage kood
    // gayi (fuel bikaa par kahin darj nahi), minus ka matlab peeche chali gayi.
    decimal GapQty
);
