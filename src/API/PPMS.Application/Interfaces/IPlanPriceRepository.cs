namespace PPMS.Application.Interfaces;

/// <summary>Login page par 6 mahine / 1 saal ke plan ka rate - Super Admin bharta hai (Section BB).</summary>
public interface IPlanPriceRepository
{
    Task<PlanPrices> GetAsync(CancellationToken cancellationToken = default);

    Task<PlanPrices> SaveAsync(decimal? price6Month, decimal? price1Year, long? byUserId, CancellationToken cancellationToken = default);
}

/// <summary>PUMP.sp_PlanPrices_Get. Null = rate nahi dikhta (dabbe me "Plan" hi).</summary>
public sealed record PlanPrices(decimal? Price6Month, decimal? Price1Year);

public sealed record SavePlanPricesRequest(decimal? Price6Month, decimal? Price1Year);
