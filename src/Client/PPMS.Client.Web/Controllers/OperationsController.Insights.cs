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

    // ───────────── GST report (Section AW) ─────────────
    private async Task<(GstReportViewModel Model, bool Allowed)> BuildGstReportAsync(string token, long? pumpId, DateOnly? dateFrom, DateOnly? dateTo, CancellationToken cancellationToken)
    {
        if (!await CanSeeMenuAsync(token, "/gst-report", cancellationToken)) return (new GstReportViewModel(), false);

        var today = DateOnly.FromDateTime(DateTime.Today);
        var from = dateFrom ?? new DateOnly(today.Year, today.Month, 1);
        var to = dateTo ?? today;
        if (to < from) (from, to) = (to, from);

        var pumps = await Api.GetPumpsAsync(token, GetOwnerId(), cancellationToken);
        var pump = pumps.FirstOrDefault(p => p.Id == pumpId) ?? pumps.FirstOrDefault();
        var model = new GstReportViewModel { Pumps = pumps, PumpId = pump?.Id ?? 0, PumpGstin = pump?.GSTIN, DateFrom = from, DateTo = to };
        if (pump is null) return (model, true);

        var lines = await Api.GetGstReportAsync(token, pump.Id, from, to, cancellationToken);
        model.Rates = lines.Where(x => x.Section == "RATE").OrderBy(x => x.SortOrder).ToList();
        model.Hsn = lines.Where(x => x.Section == "HSN").OrderBy(x => x.SortOrder).ToList();
        model.Bills = lines.Where(x => x.Section == "BILL").OrderBy(x => x.SortOrder).ToList();
        model.NonGst = lines.Where(x => x.Section == "NONGST").OrderBy(x => x.SortOrder).ThenBy(x => x.Name).ToList();
        return (model, true);
    }

    [HttpGet]
    public async Task<IActionResult> GstReport(long? pumpId, DateOnly? dateFrom, DateOnly? dateTo, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null) return RedirectToAction("Login", "Account");

        var (model, allowed) = await BuildGstReportAsync(token, pumpId, dateFrom, dateTo, cancellationToken);
        if (!allowed) return RedirectToAction(nameof(Reports));

        ViewData["Title"] = "GST Report";
        return View(model);
    }

    /// <summary>CA ke liye ek hi CSV me chaaron hisse (Excel me khulta hai).</summary>
    [HttpGet]
    public async Task<IActionResult> ExportGstReportCsv(long? pumpId, DateOnly? dateFrom, DateOnly? dateTo, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null) return RedirectToAction("Login", "Account");

        var (m, allowed) = await BuildGstReportAsync(token, pumpId, dateFrom, dateTo, cancellationToken);
        if (!allowed) return RedirectToAction(nameof(Reports));

        static string Q(string? s) => "\"" + (s ?? string.Empty).Replace("\"", "\"\"") + "\"";
        static string N(decimal v) => v.ToString("0.00", System.Globalization.CultureInfo.InvariantCulture);
        var pumpName = m.Pumps.FirstOrDefault(p => p.Id == m.PumpId)?.Name;

        var b = new System.Text.StringBuilder();
        b.AppendLine($"GST Report,{Q(pumpName)},GSTIN,{Q(m.PumpGstin)},From,{m.DateFrom:yyyy-MM-dd},To,{m.DateTo:yyyy-MM-dd}");
        b.AppendLine();
        b.AppendLine("1. Rate-wise summary");
        b.AppendLine("Rate %,Bills,Taxable value,CGST,SGST,IGST,Total");
        foreach (var r in m.Rates)
            b.AppendLine($"{N(r.Rate ?? 0)},{r.Lines},{N(r.TaxableValue)},{N(r.Cgst)},{N(r.Sgst)},{N(r.Igst)},{N(r.Total)}");
        b.AppendLine($"Total,,{N(m.Taxable)},{N(m.Cgst)},{N(m.Sgst)},{N(m.Igst)},{N(m.GrandTotal)}");
        b.AppendLine();
        b.AppendLine("2. HSN summary (GSTR-1)");
        b.AppendLine("HSN,Description,UQC,Total quantity,Rate %,Taxable value,CGST,SGST,IGST,Total value");
        foreach (var h in m.Hsn)
            b.AppendLine($"{Q(h.Code)},{Q(h.Name)},{GstReportViewModel.Uqc(h.Unit)},{h.Qty.ToString("0.###", System.Globalization.CultureInfo.InvariantCulture)},{N(h.Rate ?? 0)},{N(h.TaxableValue)},{N(h.Cgst)},{N(h.Sgst)},{N(h.Igst)},{N(h.Total)}");
        b.AppendLine();
        b.AppendLine("3. Bill-wise (B2B = party has GSTIN)");
        b.AppendLine("Date,Bill No,Customer / Party,Party GSTIN,Type,Payment Mode,Rate %,Taxable value,CGST,SGST,IGST,Total");
        foreach (var x in m.Bills)
            b.AppendLine($"{x.BillDate:yyyy-MM-dd},{Q(x.BillNo)},{Q(x.Name)},{Q(x.PartyGstin)},{(string.IsNullOrWhiteSpace(x.PartyGstin) ? "B2C" : "B2B")},{Q(x.Mode)},{(x.Rate is decimal rt ? N(rt) : "mixed")},{N(x.TaxableValue)},{N(x.Cgst)},{N(x.Sgst)},{N(x.Igst)},{N(x.Total)}");
        b.AppendLine();
        b.AppendLine("4. Non-GST supply (petrol / diesel / CNG - VAT; GSTR-3B 3.1(e))");
        b.AppendLine("Type,Product,Unit,Quantity,Value");
        foreach (var x in m.NonGst)
            b.AppendLine($"{(x.Code == "METER" ? "Meter sale" : "Bill")},{Q(x.Name)},{Q(x.Unit)},{x.Qty.ToString("0.###", System.Globalization.CultureInfo.InvariantCulture)},{N(x.Total)}");
        b.AppendLine($"Total,,,,{N(m.NonGstTotal)}");

        var bytes = System.Text.Encoding.UTF8.GetPreamble().Concat(System.Text.Encoding.UTF8.GetBytes(b.ToString())).ToArray();
        return File(bytes, "text/csv", $"GST_Report_{m.DateFrom:yyyyMMdd}_{m.DateTo:yyyyMMdd}.csv");
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
