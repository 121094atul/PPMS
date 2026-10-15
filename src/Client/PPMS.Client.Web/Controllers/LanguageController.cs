using Microsoft.AspNetCore.Localization;
using Microsoft.AspNetCore.Mvc;

namespace PPMS.Client.Web.Controllers;

/// <summary>
/// Bhasha badalne ke liye. Choice cookie me 1 saal tak yaad rehti hai, isliye
/// logout ke baad bhi wahi bhasha milti hai.
/// </summary>
public sealed class LanguageController : Controller
{
    private static readonly string[] Allowed = { "en", "hi" };

    [HttpGet]
    public IActionResult Set(string culture, string? returnUrl)
    {
        // Sirf jaanchi hui bhasha hi accept karo — kuch bhi cookie me nahi ghusna chahiye.
        if (string.IsNullOrWhiteSpace(culture) || Array.IndexOf(Allowed, culture) < 0)
        {
            culture = "en";
        }

        Response.Cookies.Append(
            CookieRequestCultureProvider.DefaultCookieName,
            CookieRequestCultureProvider.MakeCookieValue(new RequestCulture(culture)),
            new CookieOptions
            {
                Expires = DateTimeOffset.UtcNow.AddYears(1),
                IsEssential = true,
                HttpOnly = false,
                SameSite = SameSiteMode.Lax
            });

        // Open-redirect se bachne ke liye sirf apni hi site ke andar wapas bhejo.
        if (!string.IsNullOrWhiteSpace(returnUrl) && Url.IsLocalUrl(returnUrl))
        {
            return LocalRedirect(returnUrl);
        }

        return RedirectToAction("Index", "Home");
    }
}
