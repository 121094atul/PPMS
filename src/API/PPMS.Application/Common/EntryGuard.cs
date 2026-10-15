namespace PPMS.Application.Common;

/// <summary>
/// Entry-level saanity checks jo har save par lagni chahiye.
///
/// Kyun zaroori: pehle API in sab ko chupchaap accept kar leti thi —
///   * -50 litre ki sale (revenue ulta ghata deti thi)
///   * 0 litre / 0 rate ki sale (bekaar row, GST report bigadti thi)
///   * 2030 ki tareekh ki entry (mahine ka hisaab hamesha ke liye kharab)
/// UI me min="0.01" laga tha, par UI bypass karke API direct hit karne par
/// kuch nahi rokta tha. Ab server par hi rok hai.
///
/// Dhyaan rahe: stock se zyada bech dena JAANBUJH KAR nahi roka gaya — asli pump par
/// purchase ki entry kai baar der se hoti hai, aur wahan block karne se kaam ruk
/// jaata. Wo Dashboard ke "Low Tank Stock Alert" me laal dikh jaata hai.
/// </summary>
public static class EntryGuard
{
    /// <summary>Quantity/amount hamesha 0 se bada hona chahiye.</summary>
    public static void PositiveQuantity(decimal value, string fieldName)
    {
        if (value <= 0)
        {
            throw new InvalidOperationException($"{fieldName} must be greater than zero.");
        }
    }

    /// <summary>Rate 0 ya minus nahi ho sakta.</summary>
    public static void PositiveRate(decimal value, string fieldName)
    {
        if (value <= 0)
        {
            throw new InvalidOperationException($"{fieldName} must be greater than zero.");
        }
    }

    /// <summary>
    /// Purani tareekh chalegi (chhoot gayi entry ke liye), par aane wale kal ki nahi.
    /// Alag-alag timezone/clock ke liye aaj ke aakhir tak ki chhoot di gayi hai.
    /// </summary>
    public static void NotInFuture(DateTime? value, string fieldName)
    {
        if (value is null)
        {
            return;
        }

        var endOfToday = DateTime.Now.Date.AddDays(1).AddSeconds(-1);
        if (value.Value > endOfToday)
        {
            throw new InvalidOperationException($"{fieldName} cannot be a future date.");
        }
    }

    /// <inheritdoc cref="NotInFuture(DateTime?, string)"/>
    public static void NotInFuture(DateOnly? value, string fieldName)
    {
        if (value is null)
        {
            return;
        }

        if (value.Value > DateOnly.FromDateTime(DateTime.Now.Date))
        {
            throw new InvalidOperationException($"{fieldName} cannot be a future date.");
        }
    }
}
