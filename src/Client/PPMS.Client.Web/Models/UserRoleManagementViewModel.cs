using PPMS.Client.Web.Services;

namespace PPMS.Client.Web.Models;

public sealed class UserManagementViewModel
{
    public UserForm Form { get; set; } = new();
    public IReadOnlyList<ApiUserDto> Users { get; set; } = Array.Empty<ApiUserDto>();
    public IReadOnlyList<ApiRoleDto> Roles { get; set; } = Array.Empty<ApiRoleDto>();
    public string? Message { get; set; }
}

public sealed class UserForm
{
    public long? Id { get; set; }
    public long OwnerId { get; set; }
    public string FullName { get; set; } = string.Empty;
    public string Username { get; set; } = string.Empty;
    public string Password { get; set; } = string.Empty;
    public string? Mobile { get; set; }
    public long RoleId { get; set; }
}

public sealed class RoleManagementViewModel
{
    public RoleForm Form { get; set; } = new();
    public IReadOnlyList<ApiRoleDto> Roles { get; set; } = Array.Empty<ApiRoleDto>();
    public string? Message { get; set; }
}

public sealed class RoleForm
{
    public long? Id { get; set; }
    public long OwnerId { get; set; }
    public string Name { get; set; } = string.Empty;
    public bool IsSystem { get; set; }
}

public sealed class RolePermissionsViewModel
{
    public long RoleId { get; set; }
    public string RoleName { get; set; } = string.Empty;
    public List<RoleMenuForm> Menus { get; set; } = new();
}

public sealed class RoleMenuForm
{
    public long MenuId { get; set; }
    public string MenuName { get; set; } = string.Empty;
    public string Route { get; set; } = string.Empty;
    public string? Icon { get; set; }
    public bool CanView { get; set; }
    public bool CanCreate { get; set; }
    public bool CanEdit { get; set; }
    public bool CanDelete { get; set; }
}
