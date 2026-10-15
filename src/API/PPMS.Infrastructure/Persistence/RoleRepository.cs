using Dapper;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;
using PPMS.Application.Features.Roles;

namespace PPMS.Infrastructure.Persistence;

public sealed class RoleRepository(IOptions<DatabaseOptions> options) : IRoleRepository
{
    private readonly DatabaseOptions _options = options.Value;

    public async Task<IReadOnlyList<RoleDto>> GetAllAsync(long ownerId, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        var rows = await connection.QueryAsync<RoleDto>(
            sql: "PUMP.sp_Role_List",
            param: new { OwnerId = ownerId },
            commandType: System.Data.CommandType.StoredProcedure);

        return rows.AsList();
    }

    public async Task<long> SaveAsync(SaveRoleRequest request, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        var id = await connection.ExecuteScalarAsync<long>(
            sql: "PUMP.sp_Role_Save",
            param: new
            {
                Id = request.Id,
                request.OwnerId,
                request.Name,
                request.IsSystem
            },
            commandType: System.Data.CommandType.StoredProcedure);

        return id;
    }

    public async Task<IReadOnlyList<RoleMenuDto>> GetRoleMenusAsync(long roleId, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        var rows = await connection.QueryAsync<RoleMenuDto>(
            sql: "PUMP.sp_RoleMenu_GetByRole",
            param: new { RoleId = roleId },
            commandType: System.Data.CommandType.StoredProcedure);

        return rows.AsList();
    }

    public async Task SaveRoleMenusAsync(SaveRoleMenusRequest request, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_options.ConnectionString);
        
        var dt = new System.Data.DataTable();
        dt.Columns.Add("MenuId", typeof(long));
        dt.Columns.Add("CanView", typeof(bool));
        dt.Columns.Add("CanCreate", typeof(bool));
        dt.Columns.Add("CanEdit", typeof(bool));
        dt.Columns.Add("CanDelete", typeof(bool));

        foreach (var m in request.Menus)
        {
            dt.Rows.Add(m.MenuId, m.CanView, m.CanCreate, m.CanEdit, m.CanDelete);
        }

        await connection.ExecuteAsync(
            sql: "PUMP.sp_RoleMenu_Save",
            param: new
            {
                RoleId = request.RoleId,
                RoleMenus = dt.AsTableValuedParameter("PUMP.udt_RoleMenuType")
            },
            commandType: System.Data.CommandType.StoredProcedure);
    }
}
