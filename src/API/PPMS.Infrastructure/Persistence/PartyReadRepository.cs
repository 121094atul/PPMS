using Dapper;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;
using PPMS.Application.Features.Parties;
using PPMS.Shared.Models;

namespace PPMS.Infrastructure.Persistence;

public sealed class PartyReadRepository(IOptions<DatabaseOptions> options) : IPartyReadRepository
{
    private readonly DatabaseOptions _options = options.Value;

    public async Task<PagedResponse<PartyDto>> GetPagedListAsync(long ownerId, long pumpId, string? searchTerm, int pageNumber, int pageSize, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);

        using var multi = await connection.QueryMultipleAsync(
            sql: "PUMP.sp_Party_List",
            param: new
            {
                OwnerId = ownerId > 0 ? ownerId : _options.DefaultOwnerId,
                PumpId = pumpId,
                SearchTerm = searchTerm,
                PageNumber = pageNumber,
                PageSize = pageSize
            },
            commandType: System.Data.CommandType.StoredProcedure);

        var items = await multi.ReadAsync<PartyDto>();
        var totalCount = await multi.ReadSingleAsync<int>();

        return new PagedResponse<PartyDto>(items.ToList(), totalCount, pageNumber, pageSize);
    }

    public async Task<PartyDto?> GetByIdAsync(long id, long ownerId, long pumpId, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        return await connection.QueryFirstOrDefaultAsync<PartyDto>(
            sql: "PUMP.sp_Party_GetById",
            param: new
            {
                Id = id,
                OwnerId = ownerId > 0 ? ownerId : _options.DefaultOwnerId,
                PumpId = pumpId
            },
            commandType: System.Data.CommandType.StoredProcedure);
    }
}
