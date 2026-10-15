using Dapper;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;
using PPMS.Application.Features.Parties;

namespace PPMS.Infrastructure.Persistence;

public sealed class PartyCommandRepository(IOptions<DatabaseOptions> options) : IPartyCommandRepository
{
    private readonly DatabaseOptions _options = options.Value;

    public async Task SaveAsync(SavePartyRequest request, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        await connection.ExecuteAsync(
            sql: "PUMP.sp_Party_Save",
            param: new
            {
                request.Id,
                OwnerId = request.OwnerId > 0 ? request.OwnerId : _options.DefaultOwnerId,
                request.PumpId,
                request.PartyName,
                request.PartyType,
                request.Address,
                request.Mobile,
                request.Email,
                request.GSTIN,
                request.CreditLimit,
                request.CurrentBalance,
                request.IsActive,
                request.KeepBalance
            },
            commandType: System.Data.CommandType.StoredProcedure);
    }

    public async Task DeleteAsync(long id, long ownerId, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        await connection.ExecuteAsync(
            sql: "PUMP.sp_Party_Delete",
            param: new { Id = id, OwnerId = ownerId },
            commandType: System.Data.CommandType.StoredProcedure);
    }

    /// <summary>
    /// Har party ka bakaya dobara gina jaata hai (Support console):
    /// purana baki (Parties.OpeningBalance) + khaate ki line.
    ///
    /// Parties.CurrentBalance ek chalta hua jod hai — kabhi entry haath se hati ho
    /// ya koi purani gadbad ho to wo ledger se alag ho jaata hai. Ye use sach par
    /// wapas le aata hai.
    ///
    /// Section AF (2026-10-13) se pehle ye SIRF khaate ki line jodta tha aur party
    /// banate waqt bhara gaya purana baki mita deta tha. Lautne wala ank ab "kitni
    /// party ka baki sach me badla" hai — 0 ka matlab sab pehle se sahi tha.
    /// </summary>
    public async Task<int> RecalculateBalancesAsync(long ownerId, long? partyId, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        return await connection.ExecuteScalarAsync<int>(
            sql: "PUMP.sp_Party_RecalculateBalance",
            param: new { OwnerId = ownerId, PartyId = partyId },
            commandType: System.Data.CommandType.StoredProcedure);
    }
}
