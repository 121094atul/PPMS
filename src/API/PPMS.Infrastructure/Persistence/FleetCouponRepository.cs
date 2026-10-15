using Dapper;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;
using PPMS.Application.Features.FleetCoupons;

namespace PPMS.Infrastructure.Persistence;

public sealed class FleetCouponRepository(IOptions<DatabaseOptions> options) : IFleetCouponRepository
{
    private readonly DatabaseOptions _options = options.Value;

    public async Task<long> SaveFleetContractAsync(SaveFleetContractRequest request, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        return await connection.ExecuteScalarAsync<long>(
            sql: "PUMP.sp_FleetContract_Save",
            param: new
            {
                request.Id,
                request.OwnerId,
                request.PumpId,
                request.PartyId,
                request.ProductId,
                request.ContractRate,
                ValidFrom = request.ValidFrom.ToDateTime(TimeOnly.MinValue),
                ValidTo = request.ValidTo?.ToDateTime(TimeOnly.MinValue),
                request.IsActive,
                request.Notes
            },
            commandType: System.Data.CommandType.StoredProcedure);
    }

    public async Task<IReadOnlyList<FleetContractDto>> GetFleetContractsAsync(long ownerId, long pumpId, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        var rows = await connection.QueryAsync<FleetContractDto>(
            sql: "PUMP.sp_FleetContract_List",
            param: new { OwnerId = ownerId, PumpId = pumpId },
            commandType: System.Data.CommandType.StoredProcedure);

        return rows.AsList();
    }

    public async Task<long> SaveCouponBookAsync(SaveCouponBookRequest request, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        return await connection.ExecuteScalarAsync<long>(
            sql: "PUMP.sp_CouponBook_Save",
            param: new
            {
                request.Id,
                request.OwnerId,
                request.PumpId,
                request.BookCode,
                request.Denomination,
                request.TotalCoupons,
                request.IssuedToPartyId,
                request.StartSerial,
                request.EndSerial,
                request.IsActive
            },
            commandType: System.Data.CommandType.StoredProcedure);
    }

    public async Task<IReadOnlyList<CouponBookDto>> GetCouponBooksAsync(long ownerId, long pumpId, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        var rows = await connection.QueryAsync<CouponBookDto>(
            sql: "PUMP.sp_CouponBook_List",
            param: new { OwnerId = ownerId, PumpId = pumpId },
            commandType: System.Data.CommandType.StoredProcedure);

        return rows.AsList();
    }

    public async Task<long> SaveCouponTransactionAsync(SaveCouponTransactionRequest request, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        return await connection.ExecuteScalarAsync<long>(
            sql: "PUMP.sp_CouponTxn_Save",
            param: new
            {
                request.OwnerId,
                request.PumpId,
                request.CouponBookId,
                request.PartyId,
                request.SalesHeaderId,
                request.CouponSerialNo,
                request.Amount,
                request.Notes,
                request.TxnDateTime
            },
            commandType: System.Data.CommandType.StoredProcedure);
    }

    public async Task<IReadOnlyList<CouponTransactionDto>> GetCouponTransactionsAsync(long ownerId, long pumpId, long? couponBookId, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        var rows = await connection.QueryAsync<CouponTransactionDto>(
            sql: "PUMP.sp_CouponTxn_List",
            param: new { OwnerId = ownerId, PumpId = pumpId, CouponBookId = couponBookId },
            commandType: System.Data.CommandType.StoredProcedure);

        return rows.AsList();
    }
}
