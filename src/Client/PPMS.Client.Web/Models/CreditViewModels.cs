using PPMS.Client.Web.Services;

namespace PPMS.Client.Web.Models;

/// <summary>
/// SuperAdmin ki screen — aapka apna stock aur owner ke recharge.
///
/// <para>Stock wahi hai jo aapne Twilio se khareeda. Owner ko usse zyada bech nahi
/// sakte — wo rok DB me hai (<c>sp_Wallet_ApproveRecharge</c>), isliye galti se bhi
/// zyada allocate nahi hoga.</para>
/// </summary>
public sealed class PlatformCreditViewModel
{
    public ApiPlatformCreditSummary? Summary { get; set; }
    public IReadOnlyList<ApiRechargeRequestDto> Recharges { get; set; } = Array.Empty<ApiRechargeRequestDto>();

    public string? UpiId { get; set; }
    public string? UpiName { get; set; }
    public decimal? PricePerCredit { get; set; }

    public string? Message { get; set; }
    public bool IsError { get; set; }
}

/// <summary>Owner ki screen — apna balance, recharge, aur hisaab.</summary>
public sealed class WalletViewModel
{
    public ApiWalletDto? Wallet { get; set; }
    public IReadOnlyList<ApiCreditLedgerDto> Ledger { get; set; } = Array.Empty<ApiCreditLedgerDto>();
    public IReadOnlyList<ApiRechargeRequestDto> Recharges { get; set; } = Array.Empty<ApiRechargeRequestDto>();

    public string? Message { get; set; }
    public bool IsError { get; set; }

    /// <summary>Koi request abhi approve ka intezaar kar rahi hai — nayi na banne dein.</summary>
    public bool HasPending => Recharges.Any(r => r.Status == "PENDING");

    /// <summary>UPI id set hi nahi hai to recharge ka koi rasta nahi.</summary>
    public bool CanRecharge => !string.IsNullOrWhiteSpace(Wallet?.UpiId)
                               && Wallet?.PricePerCredit is > 0;
}
