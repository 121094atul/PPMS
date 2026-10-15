using Dapper;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;
using PPMS.Application.Features.Menus;

namespace PPMS.Infrastructure.Persistence;

public sealed class MenuRepository(IOptions<DatabaseOptions> options) : IMenuRepository
{
    private readonly DatabaseOptions _options = options.Value;

    public async Task<IReadOnlyList<MenuItemDto>> GetByRoleIdAsync(long roleId, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        var rows = await connection.QueryAsync<MenuItemDto>(
            sql: "PUMP.sp_Menu_GetByRole",
            param: new { RoleId = roleId },
            commandType: System.Data.CommandType.StoredProcedure);

        return rows.AsList();
    }

    public async Task<IReadOnlyList<MenuItemDto>> GetAllAsync(CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        var rows = await connection.QueryAsync<MenuItemDto>(
            sql: "PUMP.sp_Menu_GetAll",
            commandType: System.Data.CommandType.StoredProcedure);

        return rows.AsList();
    }
}
