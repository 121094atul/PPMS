namespace PPMS.Application.Features.Products;

/// <summary>
/// "Aaj ke rate" screen ki ek line. PreviousRate isliye chahiye taaki user ko
/// dikhe ki aaj rate kitna upar/neeche gaya — pump par yahi sabse pehle dekha
/// jaata hai.
/// </summary>
public sealed record DailyRateDto(
    long Id,
    long PumpId,
    string PumpName,
    string Name,
    string Category,
    string Unit,
    decimal CurrentRate,
    decimal? PreviousRate,
    DateTime? LastChangedOn
);
