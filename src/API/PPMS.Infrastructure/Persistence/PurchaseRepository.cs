using Dapper;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;
using PPMS.Application.Features.Purchases;

namespace PPMS.Infrastructure.Persistence;

public sealed class PurchaseRepository(IOptions<DatabaseOptions> options) : IPurchaseRepository
{
    private readonly DatabaseOptions _options = options.Value;

    public async Task<long> SaveAsync(SavePurchaseRequest request, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        await connection.OpenAsync(cancellationToken);
        await using var transaction = await connection.BeginTransactionAsync(cancellationToken);

        try
        {
            // Bill ka jod = har line ki BILL wali rakam ka jod (Section AE).
            var total = request.Items.Sum(x => x.LineAmount);
            long headerId;

            if (request.Id.HasValue && request.Id.Value > 0)
            {
                headerId = request.Id.Value;

                // Revert stock, delete old transactions and details
                await connection.ExecuteAsync(
                    sql: "PUMP.sp_Purchase_PrepareUpdate",
                    param: new { Id = headerId, request.OwnerId },
                    transaction: transaction,
                    commandType: System.Data.CommandType.StoredProcedure);

                // Update purchase header
                await connection.ExecuteAsync(
                    sql: "PUMP.sp_Purchase_UpdateHeader",
                    param: new
                    {
                        Id = headerId,
                        request.OwnerId,
                        request.PumpId,
                        request.VendorId,
                        request.InvoiceNo,
                        InvoiceDate = request.InvoiceDate.ToDateTime(TimeOnly.MinValue),
                        request.VehicleNo,
                        request.DriverName,
                        TotalAmount = total,
                        request.Notes,
                        ReceivedDate = request.ReceivedDate?.ToDateTime(TimeOnly.MinValue)
                    },
                    transaction: transaction,
                    commandType: System.Data.CommandType.StoredProcedure);
            }
            else
            {
                headerId = await connection.ExecuteScalarAsync<long>(
                    sql: "PUMP.sp_Purchase_SaveHeader",
                    param: new
                    {
                        request.OwnerId,
                        request.PumpId,
                        request.VendorId,
                        request.InvoiceNo,
                        InvoiceDate = request.InvoiceDate.ToDateTime(TimeOnly.MinValue),
                        request.VehicleNo,
                        request.DriverName,
                        TotalAmount = total,
                        request.Notes,
                        // Section AV: tank ki entry isi din (null = bill ka din).
                        ReceivedDate = request.ReceivedDate?.ToDateTime(TimeOnly.MinValue)
                    },
                    transaction: transaction,
                    commandType: System.Data.CommandType.StoredProcedure);
            }

            foreach (var item in request.Items)
            {
                await connection.ExecuteAsync(
                    sql: "PUMP.sp_Purchase_SaveDetail",
                    param: new
                    {
                        PurchaseHeaderId = headerId,
                        item.ProductId,
                        item.TankId,
                        item.Quantity,
                        Rate = item.LineRate,
                        Amount = item.LineAmount
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

    public async Task<PPMS.Shared.Models.PagedResponse<PurchaseDto>> GetPagedListAsync(long ownerId, long pumpId, DateTime? fromDate, DateTime? toDate, string? searchTerm, int pageNumber, int pageSize, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        using var multi = await connection.QueryMultipleAsync(
            sql: "PUMP.sp_Purchase_List",
            param: new 
            { 
                OwnerId = ownerId, 
                PumpId = pumpId,
                FromDate = fromDate,
                ToDate = toDate,
                PageNumber = pageNumber,
                PageSize = pageSize
            },
            commandType: System.Data.CommandType.StoredProcedure);

        var items = await multi.ReadAsync<PurchaseDto>();
        var totalCount = await multi.ReadSingleAsync<int>();

        return new PPMS.Shared.Models.PagedResponse<PurchaseDto>(items.ToList(), totalCount, pageNumber, pageSize);
    }

    public async Task DeleteAsync(long id, long ownerId, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        await connection.ExecuteAsync(
            sql: "PUMP.sp_Purchase_Delete",
            param: new { Id = id, OwnerId = ownerId },
            commandType: System.Data.CommandType.StoredProcedure);
    }

    public async Task<PurchaseDetailDto?> GetByIdAsync(long id, long ownerId, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        using var multi = await connection.QueryMultipleAsync(
            sql: @"SELECT Id, OwnerId, PumpId, VendorId, InvoiceNo, InvoiceDate, VehicleNo, DriverName, Notes, ReceivedDate
                   FROM PUMP.PurchaseHeaders
                   WHERE Id = @Id AND OwnerId = @OwnerId;
                   
                   SELECT ProductId, TankId, Quantity, ISNULL(Rate, 0) AS Rate, Amount
                   FROM PUMP.PurchaseDetails 
                   WHERE PurchaseHeaderId = @Id;",
            param: new { Id = id, OwnerId = ownerId });

        var header = await multi.ReadSingleOrDefaultAsync<dynamic>();
        if (header is null) return null;

        var items = await multi.ReadAsync<PurchaseDetailItemDto>();

        return new PurchaseDetailDto(
            Id: (long)header.Id,
            OwnerId: (long)header.OwnerId,
            PumpId: (long)header.PumpId,
            VendorId: (long)header.VendorId,
            InvoiceNo: (string)header.InvoiceNo,
            InvoiceDate: DateOnly.FromDateTime((DateTime)header.InvoiceDate),
            VehicleNo: (string?)header.VehicleNo,
            DriverName: (string?)header.DriverName,
            Notes: (string?)header.Notes,
            Items: items.ToList(),
            ReceivedDate: header.ReceivedDate is DateTime rd ? DateOnly.FromDateTime(rd) : null
        );
    }
}
