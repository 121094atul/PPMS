using Dapper;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;
using PPMS.Application.Features.PartyLedger;

namespace PPMS.Infrastructure.Persistence;

public sealed class PartyLedgerRepository(IOptions<DatabaseOptions> options) : IPartyLedgerRepository
{
    private readonly DatabaseOptions _options = options.Value;

    public async Task<long> SaveAsync(SavePartyLedgerEntryRequest request, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        return await connection.ExecuteScalarAsync<long>(
            sql: "PUMP.sp_PartyLedger_Save",
            param: new
            {
                request.OwnerId,
                request.PumpId,
                request.PartyId,
                request.EntryType,
                request.Amount,
                request.ReferenceNo,
                request.Notes,
                request.EntryDateTime
            },
            commandType: System.Data.CommandType.StoredProcedure);
    }

    public async Task<IReadOnlyList<PartyLedgerEntryDto>> GetByPumpAsync(long ownerId, long pumpId, long? partyId, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        var rows = await connection.QueryAsync<PartyLedgerEntryDto>(
            sql: "PUMP.sp_PartyLedger_List",
            param: new
            {
                OwnerId = ownerId,
                PumpId = pumpId,
                PartyId = partyId
            },
            commandType: System.Data.CommandType.StoredProcedure);

        return rows.AsList();
    }

    public async Task<(IReadOnlyList<PartyLedgerEntryDto> Items, int TotalCount)> GetPagedListAsync(long ownerId, long pumpId, long? partyId, string? searchTerm, int pageNumber, int pageSize, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        var multi = await connection.QueryMultipleAsync(
            sql: "PUMP.sp_PartyLedger_ListPaged",
            param: new
            {
                OwnerId = ownerId,
                PumpId = pumpId,
                PartyId = partyId,
                SearchTerm = searchTerm,
                PageNumber = pageNumber,
                PageSize = pageSize
            },
            commandType: System.Data.CommandType.StoredProcedure);

        var items = (await multi.ReadAsync<PartyLedgerEntryDto>()).ToList();
        var totalCount = await multi.ReadSingleAsync<int>();

        return (items, totalCount);
    }

    public async Task<PartyStatementDto> GetStatementAsync(long ownerId, long pumpId, long partyId, string? searchTerm, int pageNumber, int pageSize, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        var multi = await connection.QueryMultipleAsync(
            sql: "PUMP.sp_PartyLedger_Statement",
            param: new
            {
                OwnerId = ownerId,
                PumpId = pumpId,
                PartyId = partyId,
                SearchTerm = searchTerm,
                PageNumber = pageNumber,
                PageSize = pageSize
            },
            commandType: System.Data.CommandType.StoredProcedure);

        var header = await multi.ReadSingleAsync<PartyStatementHeaderDto>();
        var lines = (await multi.ReadAsync<PartyStatementLineDto>()).ToList();

        return new PartyStatementDto(header, lines, pageNumber, pageSize);
    }

    // Dono SP aakhir me ek line lautate hain (Id, PartyId, BalanceChange); `SET NOCOUNT ON`
    // ki wajah se ExecuteAsync -1 deta, isliye ExecuteScalar. Galti par SP THROW karta hai
    // (50290 nahi mili / doosre owner ki, 50291 collection-bill wali, 50292-50294 jaanch).
    public async Task UpdateAsync(long id, long ownerId, long? userId, UpdatePartyLedgerEntryRequest request, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        await connection.ExecuteScalarAsync<long>(
            sql: "PUMP.sp_PartyLedger_Update",
            param: new
            {
                Id = id,
                OwnerId = ownerId,
                request.PumpId,
                request.EntryType,
                request.Amount,
                request.EntryDateTime,
                request.ReferenceNo,
                request.Notes,
                UserId = userId,
                request.Reason
            },
            commandType: System.Data.CommandType.StoredProcedure);
    }

    public async Task DeleteAsync(long id, long ownerId, long pumpId, long? userId, string? reason, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        await connection.ExecuteScalarAsync<long>(
            sql: "PUMP.sp_PartyLedger_Delete",
            param: new
            {
                Id = id,
                OwnerId = ownerId,
                PumpId = pumpId,
                UserId = userId,
                Reason = reason
            },
            commandType: System.Data.CommandType.StoredProcedure);
    }
}
