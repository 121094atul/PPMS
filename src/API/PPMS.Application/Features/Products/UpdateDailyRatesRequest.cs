namespace PPMS.Application.Features.Products;

/// <summary>
/// Ek pump par kai fuel grade hote hain (Normal, Premium/XP95, E20 ethanol-blend,
/// Diesel, Premium Diesel) aur roz subah sabka rate alag-alag badalta hai.
/// Isliye ek hi request me har product ka apna naya rate aata hai — category-wide
/// ek rate lagana galat hai, usse saare grade barabar ho jaate hain.
/// </summary>
public sealed record ProductRateLine(long ProductId, decimal NewRate);

public sealed record UpdateDailyRatesRequest(
    long OwnerId,
    IReadOnlyList<ProductRateLine> Rates
);
