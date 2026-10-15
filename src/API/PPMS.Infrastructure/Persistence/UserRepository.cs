using Dapper;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;
using PPMS.Application.Features.Users;

namespace PPMS.Infrastructure.Persistence;

public sealed class UserRepository(IOptions<DatabaseOptions> options) : IUserRepository
{
    private readonly DatabaseOptions _options = options.Value;

    public async Task<IReadOnlyList<UserDto>> GetAllAsync(long ownerId, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        var rows = await connection.QueryAsync<UserDto>(
            sql: "PUMP.sp_User_List",
            param: new { OwnerId = ownerId },
            commandType: System.Data.CommandType.StoredProcedure);

        return rows.AsList();
    }

    public async Task<long> SaveAsync(SaveUserRequest request, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        var id = await connection.ExecuteScalarAsync<long>(
            sql: "PUMP.sp_User_Save",
            param: new
            {
                Id = request.Id,
                request.OwnerId,
                request.FullName,
                request.Username,
                PasswordHash = request.Password,
                request.Mobile,
                request.RoleId
            },
            commandType: System.Data.CommandType.StoredProcedure);

        return id;
    }

    public async Task DeleteAsync(long id, long ownerId, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        await connection.ExecuteAsync(
            sql: "PUMP.sp_User_Delete",
            param: new { Id = id, OwnerId = ownerId },
            commandType: System.Data.CommandType.StoredProcedure);
    }
}
