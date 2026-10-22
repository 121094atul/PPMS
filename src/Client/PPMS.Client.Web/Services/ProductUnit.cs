namespace PPMS.Client.Web.Services;

/// <summary>
/// Product ki ikai (Litre / Kg ...) aur "tank me stock chalta hai ya nahi" — sab screens ke liye ek hi niyam.
///
/// CNG kilo me bikti hai aur uska tank / dip / testing nahi hota (pipeline → compressor → cascade).
/// Isliye "L" / "Ltr" har jagah pakka likhna galat hai.
///
/// "Stock track nahi hota" ka niyam DB me bhi hai: Products.TracksStock (computed, Section AL) —
/// CNG aur ElectricCharging = 0. Dono jagah ek hi suchi rakhna.
/// </summary>
public static class ProductUnit
{
    /// <summary>Screen par matra ke saath likhi jaane wali chhoti ikai. Hindi me save purani ikai ("लीटर") bhi tel hai.</summary>
    public static string Abbr(string? unit)
    {
        var u = (unit ?? "Litre").Trim();
        return u.ToLowerInvariant() switch
        {
            "kg" or "किलो" => "kg",
            "kwh" => "kWh",
            "piece" or "नग" => "pcs",
            "litre" or "ltr" or "l" or "लीटर" or "" => "L",
            _ => u
        };
    }

    /// <summary>Tel (litre me) — testing aur dip isi par lagte hain.</summary>
    public static bool IsLiquid(string? unit) => Abbr(unit) == "L";

    /// <summary>False = gas / bijli: tank, dip aur tanker ka stock nahi. DB ke TracksStock se mel khaata hai.</summary>
    public static bool TracksStock(string? category) =>
        !string.Equals(category, "CNG", StringComparison.OrdinalIgnoreCase)
        && !string.Equals(category, "ElectricCharging", StringComparison.OrdinalIgnoreCase);
}
