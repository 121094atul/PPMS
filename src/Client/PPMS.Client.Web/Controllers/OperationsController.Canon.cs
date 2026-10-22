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

    private static string UnitAbbr(string? unit) => PPMS.Client.Web.Services.ProductUnit.Abbr(unit);

    private static bool IsOneOf(string? value, string[] allowed) =>
        value is not null && allowed.Contains(value, StringComparer.OrdinalIgnoreCase);
}
