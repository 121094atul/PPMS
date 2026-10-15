using Dapper;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;
using PPMS.Application.Features.DipTesting;

namespace PPMS.Infrastructure.Persistence;

public sealed class DipTestingService : IDipTestingService
{
    private readonly DatabaseOptions _options;

    public DipTestingService(IOptions<DatabaseOptions> options)
    {
        _options = options.Value;
    }

    public async Task<long> SaveDipReadingAsync(ApiSaveDipReadingRequest request, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        return await connection.ExecuteScalarAsync<long>(
            "PUMP.sp_DipReading_Save",
            request,
            commandType: System.Data.CommandType.StoredProcedure);
    }

    public async Task<PPMS.Shared.Models.PagedResponse<ApiDipReadingDto>> GetPagedDipReadingsAsync(long ownerId, long pumpId, DateTime? fromDate, DateTime? toDate, int pageNumber, int pageSize, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        using var multi = await connection.QueryMultipleAsync(
            "PUMP.sp_DipReading_List",
            new 
            { 
                OwnerId = ownerId, 
                PumpId = pumpId, 
                FromDate = fromDate, 
                ToDate = toDate,
                PageNumber = pageNumber,
                PageSize = pageSize
            },
            commandType: System.Data.CommandType.StoredProcedure);

        var items = await multi.ReadAsync<ApiDipReadingDto>();
        var totalCount = await multi.ReadSingleAsync<int>();

        return new PPMS.Shared.Models.PagedResponse<ApiDipReadingDto>(items.ToList(), totalCount, pageNumber, pageSize);
    }

    public async Task<long> SaveTestingLossAsync(ApiSaveTestingLossRequest request, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        return await connection.ExecuteScalarAsync<long>(
            "PUMP.sp_TestingLoss_Save",
            request,
            commandType: System.Data.CommandType.StoredProcedure);
    }

    public async Task<PPMS.Shared.Models.PagedResponse<ApiTestingLossDto>> GetPagedTestingLossesAsync(long ownerId, long pumpId, DateTime? fromDate, DateTime? toDate, int pageNumber, int pageSize, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        using var multi = await connection.QueryMultipleAsync(
            "PUMP.sp_TestingLoss_List",
            new 
            { 
                OwnerId = ownerId, 
                PumpId = pumpId, 
                FromDate = fromDate, 
                ToDate = toDate,
                PageNumber = pageNumber,
                PageSize = pageSize
            },
            commandType: System.Data.CommandType.StoredProcedure);

        var items = await multi.ReadAsync<ApiTestingLossDto>();
        var totalCount = await multi.ReadSingleAsync<int>();

        return new PPMS.Shared.Models.PagedResponse<ApiTestingLossDto>(items.ToList(), totalCount, pageNumber, pageSize);
    }

    public async Task<bool> UpdateDipReadingAsync(long id, ApiUpdateDipReadingRequest request, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        var param = new DynamicParameters(request);
        param.Add("@Id", id);
        // SP ka apna @@ROWCOUNT padho, Dapper ke rows-affected ka nahi: SP me
        // SET NOCOUNT ON hai, isliye ExecuteAsync hamesha -1 deta tha aur har
        // safal update "Unable to update..." bolta tha. Dekho Section AA.
        var result = await connection.ExecuteScalarAsync<int>("PUMP.sp_DipReading_Update", param, commandType: System.Data.CommandType.StoredProcedure);
        return result > 0;
    }

    public async Task<bool> ToggleDipReadingActiveAsync(long id, long ownerId, long pumpId, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        // SP ka apna @@ROWCOUNT padho, Dapper ke rows-affected ka nahi: SP me
        // SET NOCOUNT ON hai, isliye ExecuteAsync hamesha -1 deta tha aur har
        // safal update "Unable to update..." bolta tha. Dekho Section AA.
        var result = await connection.ExecuteScalarAsync<int>("PUMP.sp_DipReading_ToggleActive", new { Id = id, OwnerId = ownerId, PumpId = pumpId }, commandType: System.Data.CommandType.StoredProcedure);
        return result > 0;
    }

    public async Task<bool> UpdateTestingLossAsync(long id, ApiUpdateTestingLossRequest request, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        var param = new DynamicParameters(request);
        param.Add("@Id", id);
        // SP ka apna @@ROWCOUNT padho, Dapper ke rows-affected ka nahi: SP me
        // SET NOCOUNT ON hai, isliye ExecuteAsync hamesha -1 deta tha aur har
        // safal update "Unable to update..." bolta tha. Dekho Section AA.
        var result = await connection.ExecuteScalarAsync<int>("PUMP.sp_TestingLoss_Update", param, commandType: System.Data.CommandType.StoredProcedure);
        return result > 0;
    }

    public async Task<bool> ToggleTestingLossActiveAsync(long id, long ownerId, long pumpId, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        // SP ka apna @@ROWCOUNT padho, Dapper ke rows-affected ka nahi: SP me
        // SET NOCOUNT ON hai, isliye ExecuteAsync hamesha -1 deta tha aur har
        // safal update "Unable to update..." bolta tha. Dekho Section AA.
        var result = await connection.ExecuteScalarAsync<int>("PUMP.sp_TestingLoss_ToggleActive", new { Id = id, OwnerId = ownerId, PumpId = pumpId }, commandType: System.Data.CommandType.StoredProcedure);
        return result > 0;
    }
}
