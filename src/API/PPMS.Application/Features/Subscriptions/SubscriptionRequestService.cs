namespace PPMS.Application.Features.Subscriptions;

/// <summary>
/// NOTE: ye list PUMP.sp_SubscriptionRequest_GetList ke SELECT se bilkul match honi
/// chahiye. Pehle 9 field the par SP 13 column deta tha (City/StateCode/StateName/DoneOn
/// extra, aur RequestedOn ka naam SP me CreatedOn tha) — isliye /api/subscription-requests
/// hamesha 500 deta tha aur SuperAdmin ko plan requests kabhi dikhti hi nahi thi.
/// </summary>
public sealed record SubscriptionRequestDto(
    long Id,
    long? OwnerId,
    string ContactName,
    string ContactNo,
    string? PumpName,
    string PlanType,
    string? City,
    string? StateCode,
    string Status,
    string? Notes,
    DateTime RequestedOn,
    DateTime? DoneOn,
    string? StateName
);

public sealed record SaveSubscriptionRequest(
    string ContactName,
    string ContactNo,
    string PlanType,
    long? OwnerId = null,
    string? PumpName = null,
    // Kahan se request aayi. Table me column pehle se tha par bharta koi nahi tha —
    // galat/spam request aane par baad me pata hi nahi chalta tha ki kahan se aayi.
    // API layer bharti hai, client se nahi aati (warna jhooti IP bhej di jaati).
    string? SourceIp = null
);

public interface ISubscriptionRequestRepository
{
    Task<long> SaveAsync(SaveSubscriptionRequest request, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<SubscriptionRequestDto>> GetAllAsync(CancellationToken cancellationToken = default);
    Task MarkDoneAsync(long id, CancellationToken cancellationToken = default);
}

public interface ISubscriptionRequestService
{
    Task<long> SaveAsync(SaveSubscriptionRequest request, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<SubscriptionRequestDto>> GetAllAsync(CancellationToken cancellationToken = default);
    Task MarkDoneAsync(long id, CancellationToken cancellationToken = default);
}

public sealed class SubscriptionRequestService(ISubscriptionRequestRepository repository) : ISubscriptionRequestService
{
    public Task<long> SaveAsync(SaveSubscriptionRequest request, CancellationToken cancellationToken = default)
        => repository.SaveAsync(request, cancellationToken);

    public Task<IReadOnlyList<SubscriptionRequestDto>> GetAllAsync(CancellationToken cancellationToken = default)
        => repository.GetAllAsync(cancellationToken);

    public Task MarkDoneAsync(long id, CancellationToken cancellationToken = default)
        => repository.MarkDoneAsync(id, cancellationToken);
}
