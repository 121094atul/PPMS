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
            var spDef = connection.QueryFirstOrDefault<string>(
                "SELECT definition FROM sys.sql_modules WHERE object_id = OBJECT_ID('PUMP.sp_Purchase_SaveDetail')");
            Console.WriteLine("=== sp_Purchase_SaveDetail DEFINITION ===");
            Console.WriteLine(spDef);
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Error: {ex.Message}\n{ex.StackTrace}");
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

