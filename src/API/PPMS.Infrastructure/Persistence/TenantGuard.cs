using System.Data;
using Dapper;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Caching.Memory;
using Microsoft.Extensions.Options;
using PPMS.Application.Interfaces;

namespace PPMS.Infrastructure.Persistence;

/// <summary>
/// Ownership check ek chhoti EXISTS query hai. Har request par DB jaana mehnga
/// padega, isliye 60 second ka memory cache lagaya hai — ownership badalti nahi
/// hai (record kis owner ka hai, ye kabhi change nahi hota).
/// </summary>
public sealed class TenantGuard(IOptions<DatabaseOptions> options, IMemoryCache cache) : ITenantGuard
{
    private static readonly TimeSpan CacheFor = TimeSpan.FromSeconds(60);

    private readonly DatabaseOptions _options = options.Value;

    public async Task<bool> OwnsAsync(
        long ownerId,
        string entity,
        long entityId,
        CancellationToken cancellationToken = default)
    {
        if (ownerId <= 0 || entityId <= 0 || string.IsNullOrWhiteSpace(entity))
        {
            return false;
        }

        var key = $"own:{ownerId}:{entity}:{entityId}";
        if (cache.TryGetValue(key, out bool cached))
        {
            return cached;
        }

        await using var connection = new SqlConnection(_options.ConnectionString);

        var command = new CommandDefinition(
            commandText: "PUMP.sp_Tenant_Owns",
            parameters: new { OwnerId = ownerId, EntityName = entity, EntityId = entityId },
            commandType: CommandType.StoredProcedure,
            cancellationToken: cancellationToken);

        var owns = await connection.ExecuteScalarAsync<int>(command) == 1;

        // Sirf "haan" ko cache karo. "Nahi" cache karne se abhi-abhi bane record par
        // pehli baar galat jawab mil sakta hai.
        if (owns)
        {
            cache.Set(key, true, CacheFor);
        }

        return owns;
    }
}
