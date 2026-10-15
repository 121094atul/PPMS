namespace PPMS.Application.Interfaces;

/// <summary>
/// Message credits ka poora hisaab.
///
/// <para>Do khaate hain. <b>Platform</b> = jo aapne Twilio se khareeda (aapka stock).
/// <b>Wallet</b> = har owner ka balance. Beech me ek pakka niyam: sab owner ko mila
/// kar jitna becha hai, wo stock se zyada kabhi nahi ho sakta — ye jaanch
/// <c>sp_Wallet_ApproveRecharge</c> ke andar, lock ke saath hoti hai.</para>
///
/// <para>Ginti message me hai, rupaye me nahi: 1 credit = 1 message. Twilio ka rate
/// badalta rehta hai, isliye rupaye me rakhne par purana balance galat ho jaata.</para>
/// </summary>
public interface ICreditRepository
{
    // ---- platform (superadmin) ----
    Task<PlatformCreditSummary?> GetPlatformSummaryAsync(CancellationToken cancellationToken = default);

    Task<PlatformCreditSummary?> AddPlatformCreditAsync(AddPlatformCreditRequest request, long? userId, CancellationToken cancellationToken = default);

    Task<CreditSettings?> SaveSettingsAsync(string? upiId, string? upiName, decimal? pricePerCredit, CancellationToken cancellationToken = default);

    Task<IReadOnlyList<RechargeRequestDto>> ListRechargesAsync(long? ownerId, string? status, CancellationToken cancellationToken = default);

    Task<ApproveRechargeResult?> ApproveRechargeAsync(long requestId, long? userId, string? note, CancellationToken cancellationToken = default);

    Task RejectRechargeAsync(long requestId, long? userId, string? note, CancellationToken cancellationToken = default);

    // ---- owner ka wallet ----
    Task<WalletDto?> GetWalletAsync(long ownerId, CancellationToken cancellationToken = default);

    Task<RequestRechargeResult?> RequestRechargeAsync(long ownerId, decimal amount, string? upiReference, CancellationToken cancellationToken = default);

    Task<IReadOnlyList<CreditLedgerDto>> GetLedgerAsync(long ownerId, int topCount, CancellationToken cancellationToken = default);

    /// <summary>
    /// Sandesh bhejne se PEHLE ek credit kaatta hai. <c>Allowed = false</c> aaye to
    /// sandesh bhejna hi nahi — warna aap apne paise se doosre ka sandesh bhej denge.
    /// </summary>
    Task<ConsumeResult?> ConsumeAsync(long ownerId, string? alertKey, CancellationToken cancellationToken = default);

    /// <summary>Sandesh bhej nahi paye to kata hua credit wapas kar do.</summary>
    Task<ConsumeResult?> RefundAsync(long ownerId, string? alertKey, CancellationToken cancellationToken = default);
}

// CLAUDE.md niyam 5 — har record me SP ke saare column, usi kram me.
public sealed record PlatformCreditSummary(
    int CreditsBought, decimal AmountPaid, int CreditsAllocated,
    int CreditsAvailable, int CreditsPending, int CreditsSpent, int TenantCount);

public sealed record AddPlatformCreditRequest(
    decimal AmountPaid, int CreditsBought, string? Provider, string? ReferenceNo, string? Notes);

public sealed record CreditSettings(string UpiId, string UpiName, decimal? PricePerCredit);

public sealed record WalletDto(
    int Balance, int LifetimeAdded, int LifetimeUsed, int PendingCredits,
    string UpiId, string UpiName, decimal? PricePerCredit);

public sealed record RechargeRequestDto(
    long Id, long OwnerId, string OwnerName, DateTime RequestedOn, decimal Amount,
    int Credits, string? UpiReference, string Status, DateTime? DecidedOn, string? DecisionNote);

public sealed record RequestRechargeResult(long Id, int Credits);

public sealed record ApproveRechargeResult(string Result, long OwnerId, int Credits, int NewBalance);

public sealed record CreditLedgerDto(
    long Id, DateTime EntryOn, string EntryType, int Credits, int BalanceAfter,
    string? AlertKey, string? ReferenceNo, string? Notes);

public sealed record ConsumeResult(bool Allowed, int Balance);

// ---- API ke request shapes ----
public sealed record SaveCreditSettingsRequest(string? UpiId, string? UpiName, decimal? PricePerCredit);

public sealed record DecideRechargeRequest(string? Note);

public sealed record RequestRechargeInput(decimal Amount, string? UpiReference);
