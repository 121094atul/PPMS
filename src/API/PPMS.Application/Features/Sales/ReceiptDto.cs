namespace PPMS.Application.Features.Sales;

public sealed record ReceiptDto(
    long Id,
    long SalesHeaderId,
    string ReceiptNo,
    DateTime ReceiptDateTime,
    string BillNo,
    DateTime BillDateTime,
    string PaymentMode,
    string? VehicleNo,
    string? CustomerName,
    string? AttendantName,
    decimal TotalAmount,
    decimal TotalQuantity,
    decimal BaseAmount,
    decimal TotalCGST,
    decimal TotalSGST,
    string? PumpGSTIN,
    string? PumpAddress,
    // "kg" / "L" ... — sale ki saari line ki ikai ek ho to wahi, mili-juli ho to NULL (Section AL).
    string? QuantityUnit
)
{
    /// <summary>
    /// Purane SP (QuantityUnit ke bina, 17 column) ke liye. Dapper constructor column ginti se chunta hai,
    /// isliye build pehle chadhe ya SQL pehle - dono kram me receipt chalti rahe.
    /// </summary>
    public ReceiptDto(
        long Id, long SalesHeaderId, string ReceiptNo, DateTime ReceiptDateTime, string BillNo,
        DateTime BillDateTime, string PaymentMode, string? VehicleNo, string? CustomerName,
        string? AttendantName, decimal TotalAmount, decimal TotalQuantity, decimal BaseAmount,
        decimal TotalCGST, decimal TotalSGST, string? PumpGSTIN, string? PumpAddress)
        : this(Id, SalesHeaderId, ReceiptNo, ReceiptDateTime, BillNo, BillDateTime, PaymentMode, VehicleNo,
               CustomerName, AttendantName, TotalAmount, TotalQuantity, BaseAmount, TotalCGST, TotalSGST,
               PumpGSTIN, PumpAddress, null)
    {
    }
}
