using PPMS.Client.Web.Services;

namespace PPMS.Client.Web.Models;

public sealed class PumpManagementViewModel
{
    public PumpForm Form { get; set; } = new();
    public IReadOnlyList<ApiPumpDto> Pumps { get; set; } = Array.Empty<ApiPumpDto>();
    public string? Message { get; set; }
}

public sealed class PumpForm
{
    public long? Id { get; set; }
    public long OwnerId { get; set; }
    public string Name { get; set; } = string.Empty;
    public string? City { get; set; }
    public string? Address { get; set; }
    public string? ContactNo { get; set; }
    public string? GSTIN { get; set; }
}

public sealed class NozzleManagementViewModel
{
    public NozzleForm Form { get; set; } = new();
    public IReadOnlyList<ApiPumpDto> Pumps { get; set; } = Array.Empty<ApiPumpDto>();
    public IReadOnlyList<ApiProductDto> Products { get; set; } = Array.Empty<ApiProductDto>();
    public IReadOnlyList<ApiNozzleDto> Nozzles { get; set; } = Array.Empty<ApiNozzleDto>();
    public IReadOnlyList<ApiTankDto> Tanks { get; set; } = Array.Empty<ApiTankDto>();
    public string? Message { get; set; }
}

public sealed class NozzleForm
{
    public long? Id { get; set; }
    public long OwnerId { get; set; }
    public long PumpId { get; set; }
    public long ProductId { get; set; }
    public string NozzleCode { get; set; } = string.Empty;
    public long? TankId { get; set; }
}
