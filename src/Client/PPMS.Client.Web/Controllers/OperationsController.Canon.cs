namespace PPMS.Client.Web.Controllers;

/// <summary>
/// Form se aane wale "pehle se tay" shabd (category, unit, payment mode) sirf angrezi me DB me jaayen.
///
/// Dropdown ke option ka text Hindi me dikhta hai (@L["Petrol"] = "पेट्रोल"), aur pehle option par
/// koi alag `value` nahi tha — to Hindi mode me wahi Hindi text post hota tha. Nateeja:
///   * product ki Category "पेट्रोल" / Unit "लीटर" save hoti thi → "Aaj ke rate" me product gayab
///     (IsFuel Category se banta hai); live par Akhil pump ke dono product isi haal me hain.
///   * Sales me PaymentMode "उधार" save hota tha → "Credit" ki jaanch (party zaroori) chhoot jaati
///     aur SP `UPPER(PaymentMode) = 'CREDIT'` se udhaar ginta hi nahi tha.
/// View me ab har option ki value angrezi hai; ye list server par ek aur rok hai.
/// </summary>
public partial class OperationsController
{
    private static readonly string[] ProductCategories = { "Petrol", "Diesel", "CNG", "ElectricCharging", "Lubricant", "Accessory" };
    private static readonly string[] ProductUnits = { "Litre", "Kg", "Piece", "kWh" };
    private static readonly string[] SalePaymentModes = { "Cash", "Card", "UPI", "Credit" };
    private static readonly string[] CashPaymentModes = { "Cash", "UPI", "Card", "Bank" };

    /// <summary>
    /// Shift band hone ke baad galle me kitna nakad bachta hai. Baaki sp_Shift_Close khud Cashbook me
    /// "malik ko diya" likh deta hai (Section AN, @KeepInDrawer) - dono jagah ek hi rakam honi chahiye.
    /// Isi se agli shift ki opening banti hai.
    /// </summary>
    private const decimal CashKeptInDrawer = 0m;

    private static string UnitAbbr(string? unit) => PPMS.Client.Web.Services.ProductUnit.Abbr(unit);

    /// <summary>Ek product ki chhoti ikai (CSV header ke liye). Product na mile to "L".</summary>
    private async Task<string> ProductUnitAbbrAsync(string token, long pumpId, long productId, CancellationToken cancellationToken)
    {
        var products = await Api.GetProductsAsync(token, GetOwnerId(), pumpId, cancellationToken);
        return UnitAbbr(products.FirstOrDefault(p => p.Id == productId)?.Unit);
    }

    private static bool IsOneOf(string? value, string[] allowed) =>
        value is not null && allowed.Contains(value, StringComparer.OrdinalIgnoreCase);
}
