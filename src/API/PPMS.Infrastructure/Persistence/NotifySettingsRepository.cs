using Dapper;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;
using PPMS.Application.Interfaces;

namespace PPMS.Infrastructure.Persistence;

/// <summary>OTP / malik ke alert kis raaste se - AppSettings (Section AZ).</summary>
public sealed class NotifySettingsRepository(IOptions<DatabaseOptions> options) : INotifySettingsRepository
{
    private readonly DatabaseOptions _options = options.Value;

    public async Task<NotifySettings> GetAsync(CancellationToken cancellationToken = default)
    {
        // Naya build + purana SQL (AZ abhi nahi chala): SP nahi milega - tab default (email).
        try
        {
            await using var connection = new SqlConnection(_options.ConnectionString);
            return await connection.QuerySingleAsync<NotifySettings>(new CommandDefinition(
                "PUMP.sp_NotifySettings_Get",
                commandType: System.Data.CommandType.StoredProcedure,
                cancellationToken: cancellationToken));
        }
        catch (SqlException)
        {
            return NotifySettings.Default;
        }
    }

    public async Task<NotifySettings> SaveAsync(string otpChannel, string ownerAlertChannel, long? byUserId, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        return await connection.QuerySingleAsync<NotifySettings>(new CommandDefinition(
            "PUMP.sp_NotifySettings_Save",
            new { OtpChannel = otpChannel, OwnerAlertChannel = ownerAlertChannel, UserId = byUserId },
            commandType: System.Data.CommandType.StoredProcedure,
            cancellationToken: cancellationToken));
    }
}
