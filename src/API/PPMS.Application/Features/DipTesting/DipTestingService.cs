using PPMS.Shared.Models;

namespace PPMS.Application.Features.DipTesting;

public interface IDipTestingService
{
    Task<long> SaveDipReadingAsync(ApiSaveDipReadingRequest request, CancellationToken cancellationToken = default);
    Task<bool> UpdateDipReadingAsync(long id, ApiUpdateDipReadingRequest request, CancellationToken cancellationToken = default);
    Task<bool> ToggleDipReadingActiveAsync(long id, long ownerId, long pumpId, CancellationToken cancellationToken = default);
    Task<PPMS.Shared.Models.PagedResponse<ApiDipReadingDto>> GetPagedDipReadingsAsync(long ownerId, long pumpId, DateTime? fromDate, DateTime? toDate, int pageNumber, int pageSize, CancellationToken cancellationToken = default);
    
    Task<long> SaveTestingLossAsync(ApiSaveTestingLossRequest request, CancellationToken cancellationToken = default);
    Task<bool> UpdateTestingLossAsync(long id, ApiUpdateTestingLossRequest request, CancellationToken cancellationToken = default);
    Task<bool> ToggleTestingLossActiveAsync(long id, long ownerId, long pumpId, CancellationToken cancellationToken = default);
    Task<PPMS.Shared.Models.PagedResponse<ApiTestingLossDto>> GetPagedTestingLossesAsync(long ownerId, long pumpId, DateTime? fromDate, DateTime? toDate, int pageNumber, int pageSize, CancellationToken cancellationToken = default);
}

public sealed record ApiSaveDipReadingRequest(long OwnerId, long PumpId, long TankId, DateTime ReadingDate, long? ShiftId, decimal DipCm, decimal? WaterDipCm, decimal? Density, decimal? Temperature, decimal ExpectedStock, decimal ActualStock);
public sealed record ApiUpdateDipReadingRequest(long OwnerId, long PumpId, long TankId, DateTime ReadingDate, long? ShiftId, decimal DipCm, decimal? WaterDipCm, decimal? Density, decimal? Temperature, decimal ExpectedStock, decimal ActualStock);
public sealed record ApiDipReadingDto(long Id, long OwnerId, long PumpId, long TankId, string TankName, DateTime ReadingDate, long? ShiftId, decimal DipCm, decimal? WaterDipCm, decimal? Density, decimal? Temperature, decimal ExpectedStock, decimal ActualStock, decimal Variance, decimal? VarianceAmount, DateTime CreatedOn, bool IsActive);

public sealed record ApiSaveTestingLossRequest(long OwnerId, long PumpId, long TankId, DateTime LossDate, long? ShiftId, string LossType, decimal Quantity, string? Notes);
public sealed record ApiUpdateTestingLossRequest(long OwnerId, long PumpId, long TankId, DateTime LossDate, long? ShiftId, string LossType, decimal Quantity, string? Notes);
// ProductId/ProductName sp_TestingLoss_List se aate hain (tank ke product se derive hote
// hain). Pehle ye DTO me the hi nahi, isliye Dapper poori list materialize nahi kar pata
// tha aur /api/testing-losses hamesha 500 deta tha.
public sealed record ApiTestingLossDto(long Id, long OwnerId, long PumpId, long ProductId, string ProductName, long TankId, string TankName, DateTime LossDate, long? ShiftId, string LossType, decimal Quantity, string? Notes, DateTime CreatedOn, bool IsActive);
