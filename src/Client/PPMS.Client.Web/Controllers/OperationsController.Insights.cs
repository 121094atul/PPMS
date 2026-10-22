using Microsoft.AspNetCore.Mvc;
using PPMS.Client.Web.Models;

namespace PPMS.Client.Web.Controllers;

/// <summary>
/// Owner ki screen (Section AO / AP): Munafa (P&amp;L), Financials aur Activity Log. Menu sirf un role ko milta hai jinhe
/// "Users" milta hai (owner / admin); Roles page se kisi aur ko bhi diya ja sakta hai. Bina menu wala
/// seedha URL khole to Reports par wapas - wahi niyam jo side menu dikhata hai.
/// </summary>
public partial class OperationsController
{
    private async Task<bool> CanSeeMenuAsync(string token, string route, CancellationToken cancellationToken)
    {
        var menus = await Api.GetMenusAsync(token, cancellationToken);
        return menus.Any(m => m.CanView && string.Equals(m.Route, route, StringComparison.OrdinalIgnoreCase));
    }

    [HttpGet]
    public async Task<IActionResult> ProfitLoss(long? pumpId, DateOnly? dateFrom, DateOnly? dateTo, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null) return RedirectToAction("Login", "Account");
        if (!await CanSeeMenuAsync(token, "/profit-loss", cancellationToken)) return RedirectToAction(nameof(Reports));

        ViewData["Title"] = "Profit & Loss";
        var today = DateOnly.FromDateTime(DateTime.Today);
        var from = dateFrom ?? new DateOnly(today.Year, today.Month, 1);
        var to = dateTo ?? today;
        if (to < from) (from, to) = (to, from);

        var pumps = await Api.GetPumpsAsync(token, GetOwnerId(), cancellationToken);
        var pump = pumps.FirstOrDefault(p => p.Id == pumpId) ?? pumps.FirstOrDefault();

        var model = new ProfitLossViewModel { Pumps = pumps, PumpId = pump?.Id ?? 0, DateFrom = from, DateTo = to };
        if (pump is null) return View(model);

        var lines = await Api.GetProfitLossAsync(token, pump.Id, from, to, cancellationToken);
        model.Sales = lines.Where(x => x.Section == "SALE").OrderBy(x => x.SortOrder).ToList();
        model.Expenses = lines.Where(x => x.Section == "EXPENSE").OrderBy(x => x.SortOrder).ToList();
        model.Salary = lines.Where(x => x.Section == "SALARY").Sum(x => x.Amount);
        return View(model);
    }

    [HttpGet]
    public async Task<IActionResult> Financials(long? pumpId, DateOnly? dateFrom, DateOnly? dateTo, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null) return RedirectToAction("Login", "Account");
        if (!await CanSeeMenuAsync(token, "/financials", cancellationToken)) return RedirectToAction(nameof(Reports));

        ViewData["Title"] = "Financials";
        var today = DateOnly.FromDateTime(DateTime.Today);
        var from = dateFrom ?? new DateOnly(today.Year, today.Month, 1);
        var to = dateTo ?? today;
        if (to < from) (from, to) = (to, from);

        var pumps = await Api.GetPumpsAsync(token, GetOwnerId(), cancellationToken);
        var pump = pumps.FirstOrDefault(p => p.Id == pumpId) ?? pumps.FirstOrDefault();

        var model = new FinancialsViewModel { Pumps = pumps, PumpId = pump?.Id ?? 0, DateFrom = from, DateTo = to };
        if (pump is null) return View(model);

        model.Lines = await Api.GetFinancialsAsync(token, pump.Id, from, to, cancellationToken);
        return View(model);
    }

    [HttpGet]
    public async Task<IActionResult> ActivityLog(DateOnly? dateFrom, DateOnly? dateTo, string? area, int? page, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null) return RedirectToAction("Login", "Account");
        if (!await CanSeeMenuAsync(token, "/activity-log", cancellationToken)) return RedirectToAction(nameof(Reports));

        ViewData["Title"] = "Activity Log";
        var today = DateOnly.FromDateTime(DateTime.Today);
        var from = dateFrom ?? today.AddDays(-30);
        var to = dateTo ?? today;
        if (to < from) (from, to) = (to, from);

        var model = new ActivityLogViewModel
        {
            DateFrom = from,
            DateTo = to,
            Area = string.IsNullOrWhiteSpace(area) ? null : area.Trim().ToUpperInvariant(),
            PageNumber = Math.Max(1, page ?? 1)
        };

        var itemsTask = Api.GetActivityLogAsync(token, from, to, model.Area, model.PageNumber, model.PageSize, cancellationToken);
        var pumpsTask = Api.GetPumpsAsync(token, GetOwnerId(), cancellationToken);
        await Task.WhenAll(itemsTask, pumpsTask);

        model.Items = itemsTask.Result;
        model.TotalCount = model.Items.FirstOrDefault()?.TotalCount ?? 0;
        model.PumpNames = pumpsTask.Result.ToDictionary(p => p.Id, p => p.Name);
        return View(model);
    }
}
