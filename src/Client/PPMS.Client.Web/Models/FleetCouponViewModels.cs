using PPMS.Client.Web.Services;

namespace PPMS.Client.Web.Models;

public sealed class FleetContractsViewModel
{
    public FleetContractForm Form { get; set; } = new();
    public IReadOnlyList<ApiPumpDto> Pumps { get; set; } = Array.Empty<ApiPumpDto>();
    public IReadOnlyList<ApiPartyDto> Parties { get; set; } = Array.Empty<ApiPartyDto>();
    public IReadOnlyList<ApiProductDto> Products { get; set; } = Array.Empty<ApiProductDto>();
    public IReadOnlyList<ApiFleetContractDto> Contracts { get; set; } = Array.Empty<ApiFleetContractDto>();
    public string? Message { get; set; }
}

public sealed class FleetContractForm
{
    public long? Id { get; set; }
    public long OwnerId { get; set; }
    public long PumpId { get; set; }
    public long PartyId { get; set; }
    public long ProductId { get; set; }
    public decimal ContractRate { get; set; }
    public DateOnly ValidFrom { get; set; } = DateOnly.FromDateTime(DateTime.Today);
    public DateOnly? ValidTo { get; set; }
    public bool IsActive { get; set; } = true;
    public string? Notes { get; set; }
}

public sealed class CouponBooksViewModel
{
    public CouponBookForm Form { get; set; } = new();
    public CouponTransactionForm TxnForm { get; set; } = new();
    public IReadOnlyList<ApiPumpDto> Pumps { get; set; } = Array.Empty<ApiPumpDto>();
    public IReadOnlyList<ApiPartyDto> Parties { get; set; } = Array.Empty<ApiPartyDto>();
    public IReadOnlyList<ApiCouponBookDto> Books { get; set; } = Array.Empty<ApiCouponBookDto>();
    public IReadOnlyList<ApiCouponTransactionDto> Transactions { get; set; } = Array.Empty<ApiCouponTransactionDto>();
    public string? Message { get; set; }
}

public sealed class CouponBookForm
{
    public long? Id { get; set; }
    public long OwnerId { get; set; }
    public long PumpId { get; set; }
    public string BookCode { get; set; } = string.Empty;
    public decimal Denomination { get; set; }
    public int TotalCoupons { get; set; }
    public long? IssuedToPartyId { get; set; }
    public int StartSerial { get; set; } = 1;
    public int EndSerial { get; set; } = 100;
    public bool IsActive { get; set; } = true;
}

public sealed class CouponTransactionForm
{
    public long OwnerId { get; set; }
    public long PumpId { get; set; }
    public long CouponBookId { get; set; }
    public long? PartyId { get; set; }
    public long? SalesHeaderId { get; set; }
    public int CouponSerialNo { get; set; }
    public decimal Amount { get; set; }
    public string? Notes { get; set; }
    /// <summary>Entry ki tareekh — purani (chhoot gayi) entry ke liye badli ja sakti hai.</summary>
    public DateTime TxnDateTime { get; set; } = DateTime.Now;
}
