using Dapper;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;
using PPMS.Application.Features.Sales;

namespace PPMS.Infrastructure.Persistence;

public sealed class SalesRepository(IOptions<DatabaseOptions> options) : ISalesRepository
{
    private readonly DatabaseOptions _options = options.Value;

    public async Task<long> SaveAsync(SaveSaleRequest request, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        await connection.OpenAsync(cancellationToken);
        await using var transaction = await connection.BeginTransactionAsync(cancellationToken);

        try
        {
            var now = DateTime.Now;
            var financialYear = ResolveFinancialYear(now);
            var billNo = await connection.ExecuteScalarAsync<string>(
                sql: "PUMP.sp_NumberSeries_Next",
                param: new
                {
                    request.OwnerId,
                    request.PumpId,
                    SeriesKey = "BILL",
                    FinancialYear = financialYear,
                    Prefix = $"BIL{financialYear.Replace("-", string.Empty)}/",
                    PaddingLength = 6
                },
                transaction: transaction,
                commandType: System.Data.CommandType.StoredProcedure);
            var total = request.Items.Sum(i => i.Quantity * i.Rate);

            if (string.Equals(request.PaymentMode, "Credit", StringComparison.OrdinalIgnoreCase) && (request.PartyId ?? 0) > 0)
            {
                var party = await connection.QueryFirstOrDefaultAsync<PartyCreditRow>(
                    @"SELECT CreditLimit, CurrentBalance
                      FROM PUMP.Parties
                      WHERE Id = @PartyId
                        AND OwnerId = @OwnerId
                        AND PumpId = @PumpId
                        AND IsActive = 1",
                    new
                    {
                        PartyId = request.PartyId,
                        request.OwnerId,
                        request.PumpId
                    },
                    transaction: transaction);

                if (party is null)
                {
                    throw new InvalidOperationException("Selected party is not valid for this pump.");
                }

                var projectedBalance = party.CurrentBalance + total;
                if (projectedBalance > party.CreditLimit)
                {
                    throw new InvalidOperationException($"Credit limit exceeded. Limit: {party.CreditLimit:0.00}, Outstanding after sale: {projectedBalance:0.00}");
                }
            }

            var headerId = await connection.ExecuteScalarAsync<long>(
                sql: "PUMP.sp_Sales_SaveHeader",
                param: new
                {
                    request.OwnerId,
                    request.PumpId,
                    request.ShiftId,
                    BillNo = billNo,
                    // Purani tareekh di ho to wahi lagao (chhoot gayi entries poori karne
                    // ke liye), warna abhi ka waqt.
                    BillDateTime = request.BillDateTime ?? now,
                    request.PaymentMode,
                    request.PartyId,
                    request.VehicleNo,
                    request.CustomerName,
                    request.AttendantName,
                    TotalAmount = total
                },
                transaction: transaction,
                commandType: System.Data.CommandType.StoredProcedure);

            foreach (var item in request.Items)
            {
                await connection.ExecuteAsync(
                    sql: "PUMP.sp_Sales_SaveDetail",
                    param: new
                    {
                        SalesHeaderId = headerId,
                        // SP ab khud jaanchta hai ki header aur product isi owner ke
                        // hain (Section M) — galat bill me line na ghus jaye.
                        request.OwnerId,
                        item.ProductId,
                        item.NozzleNo,
                        item.Quantity,
                        item.Rate,
                        Amount = item.Quantity * item.Rate,
                        item.BaseAmount,
                        item.CGSTAmount,
                        item.SGSTAmount
                    },
                    transaction: transaction,
                    commandType: System.Data.CommandType.StoredProcedure);
            }

            await transaction.CommitAsync(cancellationToken);
            return headerId;
        }
        catch
        {
            await transaction.RollbackAsync(cancellationToken);
            throw;
        }
    }

    public async Task<IReadOnlyList<SaleDto>> GetAllAsync(long ownerId, long? pumpId, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        var rows = await connection.QueryAsync<SaleDto>(
            sql: "PUMP.sp_Sales_List",
            param: new
            {
                OwnerId = ownerId,
                PumpId = pumpId
            },
            commandType: System.Data.CommandType.StoredProcedure);

        return rows.AsList();
    }

    public async Task<PPMS.Shared.Models.PagedResponse<SaleDto>> GetPagedListAsync(long ownerId, long? pumpId, DateTime? fromDate, DateTime? toDate, string? searchTerm, int pageNumber, int pageSize, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);

        using var multi = await connection.QueryMultipleAsync(
            sql: "PUMP.sp_Sales_List",
            param: new
            {
                OwnerId = ownerId,
                PumpId = pumpId,
                FromDate = fromDate,
                ToDate = toDate,
                SearchTerm = searchTerm,
                PageNumber = pageNumber,
                PageSize = pageSize
            },
            commandType: System.Data.CommandType.StoredProcedure);

        var items = await multi.ReadAsync<SaleDto>();
        var totalCount = await multi.ReadSingleAsync<int>();

        return new PPMS.Shared.Models.PagedResponse<SaleDto>(items.ToList(), totalCount, pageNumber, pageSize);
    }

    public async Task<ReceiptDto?> GenerateReceiptAsync(long salesHeaderId, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        return await connection.QueryFirstOrDefaultAsync<ReceiptDto>(
            sql: "PUMP.sp_Receipt_Generate",
            param: new { SalesHeaderId = salesHeaderId },
            commandType: System.Data.CommandType.StoredProcedure);
    }

    private static string ResolveFinancialYear(DateTime utcDateTime)
    {
        var date = utcDateTime.Date;
        var startYear = date.Month >= 4 ? date.Year : date.Year - 1;
        var endYearShort = (startYear + 1) % 100;
        return $"{startYear}-{endYearShort:00}";
    }

    private sealed record PartyCreditRow(decimal CreditLimit, decimal CurrentBalance);

    public async Task VoidAsync(long id, long ownerId, long? userId, string? reason, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        await connection.ExecuteAsync(
            sql: "PUMP.sp_Sale_Void",
            param: new { Id = id, OwnerId = ownerId, UserId = userId, Reason = reason },
            commandType: System.Data.CommandType.StoredProcedure);
    }
}
