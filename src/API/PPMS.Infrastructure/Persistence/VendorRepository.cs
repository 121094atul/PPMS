using Dapper;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;
using PPMS.Application.Features.Vendors;

namespace PPMS.Infrastructure.Persistence;

public sealed class VendorRepository(IOptions<DatabaseOptions> options) : IVendorRepository
{
    private readonly DatabaseOptions _options = options.Value;

    public async Task<long> SaveAsync(SaveVendorRequest request, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        return await connection.ExecuteScalarAsync<long>(
            sql: "PUMP.sp_Vendor_Save",
            param: new
            {
                request.Id,
                request.OwnerId,
                request.PumpId,
                request.VendorName,
                request.ContactNo,
                request.GSTIN,
                request.Address,
                request.IsActive
            },
            commandType: System.Data.CommandType.StoredProcedure);
    }

    public async Task<IReadOnlyList<VendorDto>> GetByPumpAsync(long ownerId, long pumpId, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        var rows = await connection.QueryAsync<VendorDto>(
            sql: "PUMP.sp_Vendor_List",
            param: new { OwnerId = ownerId, PumpId = pumpId },
            commandType: System.Data.CommandType.StoredProcedure);

        return rows.AsList();
    }

    public async Task DeleteAsync(long id, long ownerId, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        await connection.ExecuteAsync(
            sql: "PUMP.sp_Vendor_Delete",
            param: new { Id = id, OwnerId = ownerId },
            commandType: System.Data.CommandType.StoredProcedure);
    }
}
