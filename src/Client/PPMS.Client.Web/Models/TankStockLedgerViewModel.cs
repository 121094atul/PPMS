using PPMS.Client.Web.Services;

namespace PPMS.Client.Web.Models;

public sealed class TankStockViewModel
{
    public TankStockForm Form { get; set; } = new();
    public IReadOnlyList<ApiPumpDto> Pumps { get; set; } = Array.Empty<ApiPumpDto>();
    public IReadOnlyList<ApiTankDto> Tanks { get; set; } = Array.Empty<ApiTankDto>();
    public IReadOnlyList<ApiTankTransactionDto> Transactions { get; set; } = Array.Empty<ApiTankTransactionDto>();
    public string? Message { get; set; }
}

public sealed class TankStockForm
{
    public long OwnerId { get; set; }
    public long PumpId { get; set; }
    public long TankId { get; set; }
    public string TxnType { get; set; } = "IN";
    public decimal Quantity { get; set; }
    public string? ReferenceNo { get; set; }
    public string? Notes { get; set; }
    /// <summary>Entry ki tareekh — purani (chhoot gayi) entry ke liye badli ja sakti hai.</summary>
    public DateTime TxnDateTime { get; set; } = DateTime.Now;
}

public sealed class PartyLedgerViewModel
{
    public PartyLedgerForm Form { get; set; } = new();
    public IReadOnlyList<ApiPumpDto> Pumps { get; set; } = Array.Empty<ApiPumpDto>();
    public IReadOnlyList<ApiPartyDto> Parties { get; set; } = Array.Empty<ApiPartyDto>();
    public ApiPagedResponse<ApiPartyLedgerEntryDto>? LedgerEntries { get; set; }
    /// <summary>
    /// Chuni hui party ka khaata purane baki aur chalte hue baki ke saath.
    /// null ho to page LedgerEntries wali purani saadi list dikhata hai.
    /// </summary>
    public ApiPartyStatementDto? Statement { get; set; }
    public string? SearchTerm { get; set; }
    public string? Message { get; set; }
}

public sealed class PartyLedgerForm
{
    /// <summary>0 = nayi entry. Isse zyada = us entry ko sudharna (Section AI).</summary>
    public long Id { get; set; }
    /// <summary>Sudharte waqt "kyun" — zaroori, AuditLog me jaata hai.</summary>
    public string? Reason { get; set; }
    public long OwnerId { get; set; }
    public long PumpId { get; set; }
    public long PartyId { get; set; }
    public DateTime EntryDate { get; set; } = DateTime.Today;
    public string EntryType { get; set; } = "RECEIPT";
    public decimal Amount { get; set; }
    public string? ReferenceNo { get; set; }
    public string? Notes { get; set; }
}
