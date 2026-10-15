using PPMS.Client.Web.Services;

namespace PPMS.Client.Web.Models;

public sealed class TankManagementViewModel
{
    public TankForm Form { get; set; } = new();
    public IReadOnlyList<ApiPumpDto> Pumps { get; set; } = Array.Empty<ApiPumpDto>();
    public IReadOnlyList<ApiProductDto> Products { get; set; } = Array.Empty<ApiProductDto>();
    public IReadOnlyList<ApiTankDto> Tanks { get; set; } = Array.Empty<ApiTankDto>();
    public string? SearchTerm { get; set; }
    public string? Message { get; set; }
}

public sealed class TankForm
{
    public long Id { get; set; }
    public long OwnerId { get; set; }
    public long PumpId { get; set; }
    public string Name { get; set; } = string.Empty;
    public long ProductId { get; set; }
    public decimal Capacity { get; set; }
    public decimal SafeFillLevel { get; set; }
    public decimal CurrentStock { get; set; }
    public bool IsActive { get; set; } = true;
}

public sealed class PartyManagementViewModel
{
    public PartyForm Form { get; set; } = new();
    public IReadOnlyList<ApiPumpDto> Pumps { get; set; } = Array.Empty<ApiPumpDto>();
    public IReadOnlyList<ApiPartyDto> Parties { get; set; } = Array.Empty<ApiPartyDto>();
    /// <summary>
    /// List ka kaun sa page dikh raha hai, kul kitni party hain. Pehle sirf pehli 50
    /// aati thi aur aage jaane ka koi rasta nahi tha — 51vi party list me milti hi nahi thi.
    /// </summary>
    public int PageNumber { get; set; } = 1;
    public int PageSize { get; set; } = 25;
    public int TotalCount { get; set; }
    public int TotalPages => PageSize <= 0 ? 1 : Math.Max(1, (int)Math.Ceiling(TotalCount / (double)PageSize));
    public string? SearchTerm { get; set; }
    public string? Message { get; set; }
}

public sealed class PartyForm
{
    public long Id { get; set; }
    public long OwnerId { get; set; }
    public long PumpId { get; set; }
    public string PartyName { get; set; } = string.Empty;
    public string PartyType { get; set; } = "Fleet";
    public string Address { get; set; } = string.Empty;
    public string Mobile { get; set; } = string.Empty;
    public string Email { get; set; } = string.Empty;
    public string GSTIN { get; set; } = string.Empty;
    public decimal CreditLimit { get; set; }
    public decimal CurrentBalance { get; set; }
    /// <summary>
    /// Form khulte waqt ka baki (hidden). Save par CurrentBalance isi ke barabar ho to
    /// user ne baki chhua hi nahi — tab server ko baki badalne se roka jaata hai, warna
    /// form khulne ke baad aayi jama / udhaar form ke purane ank se dab jaati.
    /// </summary>
    public decimal OriginalBalance { get; set; }
    public bool IsActive { get; set; } = true;
}
