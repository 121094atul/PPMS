using Microsoft.AspNetCore.Mvc;
using PPMS.Client.Web.Services;

namespace PPMS.Client.Web.ViewComponents;

public sealed class SideMenuViewComponent(PPMSApiClient apiClient) : ViewComponent
{
    public async Task<IViewComponentResult> InvokeAsync()
    {
        var token = HttpContext.Session.GetString("access_token");
        if (string.IsNullOrWhiteSpace(token))
        {
            return View(new List<MenuGroup>());
        }

        var menuItems = await apiClient.GetMenusAsync(token, HttpContext.RequestAborted);
        var groups = menuItems
            .OrderBy(x => x.Sequence)
            .GroupBy(x => ResolveGroup(x.Route))
            .Select(x => new MenuGroup(x.Key, x.ToList()))
            .ToList();

        return View(groups);
    }

    private static string ResolveGroup(string route)
    {
        if (route.StartsWith("/product", StringComparison.OrdinalIgnoreCase) ||
            route.StartsWith("/rate", StringComparison.OrdinalIgnoreCase) ||
            route.StartsWith("/pump", StringComparison.OrdinalIgnoreCase) ||
            route.StartsWith("/nozzle", StringComparison.OrdinalIgnoreCase) ||
            route.StartsWith("/tank", StringComparison.OrdinalIgnoreCase) ||
            route.StartsWith("/party", StringComparison.OrdinalIgnoreCase) ||
            route.StartsWith("/vendor", StringComparison.OrdinalIgnoreCase) ||
            route.StartsWith("/fleet-contract", StringComparison.OrdinalIgnoreCase) ||
            route.StartsWith("/coupon-book", StringComparison.OrdinalIgnoreCase))
        {
            return "Masters";
        }

        if (route.StartsWith("/shift", StringComparison.OrdinalIgnoreCase) ||
            route.StartsWith("/sales", StringComparison.OrdinalIgnoreCase) ||
            route.StartsWith("/tank-stock", StringComparison.OrdinalIgnoreCase) ||
            route.StartsWith("/party-ledger", StringComparison.OrdinalIgnoreCase) ||
            route.StartsWith("/purchase", StringComparison.OrdinalIgnoreCase) ||
            route.StartsWith("/stock-reconcile", StringComparison.OrdinalIgnoreCase) ||
            route.StartsWith("/dip-testing", StringComparison.OrdinalIgnoreCase) ||
            route.StartsWith("/cashbook", StringComparison.OrdinalIgnoreCase) ||
            route.StartsWith("/expenses", StringComparison.OrdinalIgnoreCase))
        {
            return "Operations";
        }

        if (route.StartsWith("/user", StringComparison.OrdinalIgnoreCase) ||
            route.StartsWith("/role", StringComparison.OrdinalIgnoreCase) ||
            route.StartsWith("/employee", StringComparison.OrdinalIgnoreCase) ||
            route.StartsWith("/salary", StringComparison.OrdinalIgnoreCase))
        {
            return "Management";
        }

        if (route.StartsWith("/report", StringComparison.OrdinalIgnoreCase) ||
            route.StartsWith("/day-book", StringComparison.OrdinalIgnoreCase) ||
            route.StartsWith("/outstanding", StringComparison.OrdinalIgnoreCase) ||
            route.StartsWith("/pump-comparison", StringComparison.OrdinalIgnoreCase) ||
            route.StartsWith("/daily-stock-register", StringComparison.OrdinalIgnoreCase) ||
            // Naya maahwar register bhi report hi hai. Iske bina ye "General" me
            // chala jaata tha - "/sale-purchase-register" upar ki kisi shart se
            // milta hi nahi (Operations wali shart "/sales" dhoondhti hai).
            route.StartsWith("/sale-purchase-register", StringComparison.OrdinalIgnoreCase))
        {
            return "Reports";
        }

        return "General";
    }
}
