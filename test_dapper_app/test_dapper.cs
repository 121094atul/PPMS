using System;
using System.Data.SqlClient;
using Dapper;

namespace TestDapper
{
    class Program
    {
        static void Main(string[] args)
        {
            try
            {
                var connectionString = "Data Source=103.235.104.111;Initial Catalog=PPMSDB;User Id=PPMSUser;Password=<password>;Encrypt=True;TrustServerCertificate=True;MultipleActiveResultSets=true;Connect Timeout=60;";
                using var connection = new SqlConnection(connectionString);
                
                Console.WriteLine("Altering PUMP.sp_User_List...");
                string sqlUser = @"
CREATE OR ALTER PROCEDURE PUMP.sp_User_List
(
    @OwnerId BIGINT
)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        u.Id,
        u.OwnerId,
        u.FullName,
        u.Username,
        u.Mobile,
        u.IsActive,
        r.Id AS RoleId,
        r.Name AS RoleName,
        u.IsSuperAdmin
    FROM PUMP.Users u
    LEFT JOIN PUMP.UserRoles ur ON ur.UserId = u.Id
    LEFT JOIN PUMP.Roles r ON r.Id = ur.RoleId
    WHERE u.IsActive = 1
      AND u.OwnerId = @OwnerId
    ORDER BY u.Id DESC;
END";
                connection.Execute(sqlUser);
                Console.WriteLine("PUMP.sp_User_List altered successfully.");

                Console.WriteLine("Altering PUMP.sp_Menu_GetAll...");
                string sqlMenu = @"
CREATE OR ALTER PROCEDURE PUMP.sp_Menu_GetAll
AS
BEGIN
    SET NOCOUNT ON;
    SELECT 
        Id,
        ParentId,
        MenuName,
        Route,
        Icon,
        Sequence,
        CAST(0 AS BIT) AS CanView,
        CAST(0 AS BIT) AS CanCreate,
        CAST(0 AS BIT) AS CanEdit,
        CAST(0 AS BIT) AS CanDelete
    FROM PUMP.Menus
    WHERE IsActive = 1
    ORDER BY Sequence, MenuName;
END";
                connection.Execute(sqlMenu);
                Console.WriteLine("PUMP.sp_Menu_GetAll altered successfully.");
            }
            catch (Exception ex)
            {
                Console.WriteLine("Error: " + ex.ToString());
            }
        }
    }
}
