using Dapper;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;
using PPMS.Application.Interfaces;

namespace PPMS.Infrastructure.Persistence;

/// <summary>Support ke number - AppSettings (Section AR).</summary>
public sealed class SupportContactRepository(IOptions<DatabaseOptions> options) : ISupportContactRepository
{
    private readonly DatabaseOptions _options = options.Value;

    public async Task<SupportContacts> GetAsync(CancellationToken cancellationToken = default)
    {
        // Number sirf dikhane ke liye hai - padhna fail ho (jaise build pehle, AR SQL baad me)
        // to sign-up / forgot-password na ruke, bas number na dikhe.
        try
        {
            await using var connection = new SqlConnection(_options.ConnectionString);
            var row = await connection.QueryFirstOrDefaultAsync<SupportContacts>(
                sql: "PUMP.sp_SupportContacts_Get",
                commandType: System.Data.CommandType.StoredProcedure);
            return row ?? new SupportContacts(null, null, null);
        }
        catch (SqlException)
        {
            return new SupportContacts(null, null, null);
        }
    }

    public async Task<SupportContacts> SaveAsync(string phone1, string? phone2, string? phone3, long? userId, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        var row = await connection.QueryFirstOrDefaultAsync<SupportContacts>(
            sql: "PUMP.sp_SupportContacts_Save",
            param: new { Phone1 = phone1, Phone2 = phone2, Phone3 = phone3, UserId = userId },
            commandType: System.Data.CommandType.StoredProcedure);
        return row ?? new SupportContacts(phone1, phone2, phone3);
    }
}
