namespace PPMS.Application.Features.FleetCoupons;

public sealed record FleetContractDto(
    long Id,
    long OwnerId,
    long PumpId,
    long PartyId,
    string PartyName,
    long ProductId,
    string ProductName,
    decimal ContractRate,
    DateTime ValidFrom,
    DateTime? ValidTo,
    bool IsActive,
    string? Notes
);

public sealed record SaveFleetContractRequest(
    long? Id,
    long OwnerId,
    long PumpId,
    long PartyId,
    long ProductId,
    decimal ContractRate,
    DateOnly ValidFrom,
    DateOnly? ValidTo,
    bool IsActive,
    string? Notes
);

public sealed record CouponBookDto(
    long Id,
    long OwnerId,
    long PumpId,
    string BookCode,
    decimal Denomination,
    int TotalCoupons,
    long? IssuedToPartyId,
    string? IssuedToPartyName,
    int StartSerial,
    int EndSerial,
    bool IsActive,
    DateTime CreatedOn
);

public sealed record SaveCouponBookRequest(
    long? Id,
    long OwnerId,
    long PumpId,
    string BookCode,
    decimal Denomination,
    int TotalCoupons,
    long? IssuedToPartyId,
    int StartSerial,
    int EndSerial,
    bool IsActive
);

public sealed record CouponTransactionDto(
    long Id,
    long OwnerId,
    long PumpId,
    long CouponBookId,
    string BookCode,
    long? PartyId,
    string? PartyName,
    long? SalesHeaderId,
    int CouponSerialNo,
    decimal Amount,
    DateTime TxnDateTime,
    string? Notes
);

public sealed record SaveCouponTransactionRequest(
    long OwnerId,
    long PumpId,
    long CouponBookId,
    long? PartyId,
    long? SalesHeaderId,
    int CouponSerialNo,
    decimal Amount,
    string? Notes,
    // Chhoot gayi entry purani tareekh par charhane ke liye. NULL = abhi ka waqt.
    DateTime? TxnDateTime = null
);

public interface IFleetCouponRepository
{
    Task<long> SaveFleetContractAsync(SaveFleetContractRequest request, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<FleetContractDto>> GetFleetContractsAsync(long ownerId, long pumpId, CancellationToken cancellationToken = default);
    Task<long> SaveCouponBookAsync(SaveCouponBookRequest request, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<CouponBookDto>> GetCouponBooksAsync(long ownerId, long pumpId, CancellationToken cancellationToken = default);
    Task<long> SaveCouponTransactionAsync(SaveCouponTransactionRequest request, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<CouponTransactionDto>> GetCouponTransactionsAsync(long ownerId, long pumpId, long? couponBookId, CancellationToken cancellationToken = default);
}

public interface IFleetCouponService
{
    Task<long> SaveFleetContractAsync(SaveFleetContractRequest request, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<FleetContractDto>> GetFleetContractsAsync(long ownerId, long pumpId, CancellationToken cancellationToken = default);
    Task<long> SaveCouponBookAsync(SaveCouponBookRequest request, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<CouponBookDto>> GetCouponBooksAsync(long ownerId, long pumpId, CancellationToken cancellationToken = default);
    Task<long> SaveCouponTransactionAsync(SaveCouponTransactionRequest request, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<CouponTransactionDto>> GetCouponTransactionsAsync(long ownerId, long pumpId, long? couponBookId, CancellationToken cancellationToken = default);
}

public sealed class FleetCouponService(IFleetCouponRepository repository) : IFleetCouponService
{
    public Task<long> SaveFleetContractAsync(SaveFleetContractRequest request, CancellationToken cancellationToken = default)
        => repository.SaveFleetContractAsync(request, cancellationToken);

    public Task<IReadOnlyList<FleetContractDto>> GetFleetContractsAsync(long ownerId, long pumpId, CancellationToken cancellationToken = default)
        => repository.GetFleetContractsAsync(ownerId, pumpId, cancellationToken);

    public Task<long> SaveCouponBookAsync(SaveCouponBookRequest request, CancellationToken cancellationToken = default)
        => repository.SaveCouponBookAsync(request, cancellationToken);

    public Task<IReadOnlyList<CouponBookDto>> GetCouponBooksAsync(long ownerId, long pumpId, CancellationToken cancellationToken = default)
        => repository.GetCouponBooksAsync(ownerId, pumpId, cancellationToken);

    public Task<long> SaveCouponTransactionAsync(SaveCouponTransactionRequest request, CancellationToken cancellationToken = default)
        => repository.SaveCouponTransactionAsync(request, cancellationToken);

    public Task<IReadOnlyList<CouponTransactionDto>> GetCouponTransactionsAsync(long ownerId, long pumpId, long? couponBookId, CancellationToken cancellationToken = default)
        => repository.GetCouponTransactionsAsync(ownerId, pumpId, couponBookId, cancellationToken);
}
