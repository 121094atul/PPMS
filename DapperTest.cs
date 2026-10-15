using System;
using System.Data;
using Microsoft.Data.SqlClient;
using Dapper;

class Program
{
    static void Main()
    {
        string connStr = "Data Source=103.235.104.111;Initial Catalog=PPMSDB;User Id=PPMSUser;Password=<password>;Encrypt=True;TrustServerCertificate=True;";
        try
        {
            using var connection = new SqlConnection(connStr);
            connection.Open();
            var rows = connection.Query<DailyStockRegisterDto>(
                sql: "PUMP.sp_Report_DailyStockRegister",
                param: new { PumpId = 1, ProductId = 2, Month = 6, Year = 2026 },
                commandType: CommandType.StoredProcedure);
            
            Console.WriteLine($"Success. Rows count: {rows.AsList().Count}");
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Error: {ex.Message}");
        }
    }
}

public sealed record DailyStockRegisterDto(
    int DayOfMonth,
    DateTime Date,
    decimal OpeningStock,
    decimal Receipt,
    decimal TotalStock,
    decimal SalesByMeter,
    decimal PumpTest,
    decimal NetSalesByMeter,
    decimal CumulativeSales,
    decimal SalesByDip,
    decimal VariationDaily,
    decimal VariationCumulative,
    string? Remarks
);
