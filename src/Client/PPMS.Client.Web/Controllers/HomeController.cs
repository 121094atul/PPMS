using System.Diagnostics;
using Microsoft.AspNetCore.Mvc;
using PPMS.Client.Web.Filters;
using PPMS.Client.Web.Models;
using PPMS.Client.Web.Services;

namespace PPMS.Client.Web.Controllers;

[SessionAuthorize]
public class HomeController(PPMSApiClient apiClient) : Controller
{
    public async Task<IActionResult> Index(long? pumpId, string? monthYear, CancellationToken cancellationToken)
    {
        var token = HttpContext.Session.GetString("access_token");
        if (string.IsNullOrWhiteSpace(token))
        {
            return RedirectToAction("Login", "Account");
        }

        var ownerId = GetOwnerId();
        var pumps = await apiClient.GetPumpsAsync(token, ownerId, cancellationToken);
        var selectedPumpId = pumpId ?? pumps.FirstOrDefault()?.Id ?? 0;

        // Generate Available Months (last 12 months)
        var today = DateTime.Today;
        var availableMonths = new List<(string Value, string Label)>();
        for (int i = 0; i < 12; i++)
        {
            var mDate = today.AddMonths(-i);
            var val = mDate.ToString("yyyy-MM");
            var lbl = mDate.ToString("MMMM yyyy");
            if (i == 0) lbl += " (Current)";
            availableMonths.Add((val, lbl));
        }

        // Determine target month & year
        DateTime targetMonthStart;
        if (!string.IsNullOrWhiteSpace(monthYear) && DateTime.TryParseExact(monthYear + "-01", "yyyy-MM-dd", System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.None, out var parsedStart))
        {
            targetMonthStart = parsedStart;
        }
        else
        {
            targetMonthStart = new DateTime(today.Year, today.Month, 1);
        }
        var targetMonthEnd = targetMonthStart.AddMonths(1).AddDays(-1);
        var selectedMonthYearVal = targetMonthStart.ToString("yyyy-MM");
        var selectedMonthLabel = targetMonthStart.ToString("MMM yyyy").ToUpper();

        // Sirf chune hue mahine ki shift chahiye — aur "chhooti hui entry" wala panel
        // pichhle mahine tak dekhta hai, isliye ek mahina peeche se lete hain.
        // Pehle yahan "saari shift" maangi jaati thi jo chupchaap 50 par kat jaati
        // thi — busy pump par mahine ka total hi galat ban jaata.
        var shiftsFrom = DateOnly.FromDateTime(targetMonthStart.AddMonths(-1));
        var shiftsTo = DateOnly.FromDateTime(targetMonthEnd);

        var shiftsTask = apiClient.GetShiftsAsync(
            token, ownerId, selectedPumpId > 0 ? selectedPumpId : null,
            shiftsFrom, shiftsTo, 1000, cancellationToken);
        var salesTask = apiClient.GetSalesAsync(
            token,
            ownerId,
            selectedPumpId > 0 ? selectedPumpId : null,
            fromDate: null,
            toDate: null,
            searchTerm: null,
            pageNumber: 1,
            pageSize: 5000,
            cancellationToken);
        var expensesTask = selectedPumpId > 0
            ? apiClient.GetExpensesAsync(token, ownerId, selectedPumpId, cancellationToken)
            : Task.FromResult<IReadOnlyList<ApiExpenseDto>>(Array.Empty<ApiExpenseDto>());
        var outstandingTask = selectedPumpId > 0
            ? apiClient.GetOutstandingAsync(token, ownerId, selectedPumpId, cancellationToken)
            : Task.FromResult<IReadOnlyList<ApiOutstandingPartyDto>>(Array.Empty<ApiOutstandingPartyDto>());
        var tanksTask = apiClient.GetTanksAsync(token, ownerId, selectedPumpId, null, 1, 1000, cancellationToken);

        // Sirf setup ki checklist ke liye. Ye do call sasti hain (master data) aur
        // sab ho jaane par checklist gayab ho jaati hai, phir bhi list chhoti rehti.
        var productsTask = apiClient.GetProductsAsync(token, ownerId, selectedPumpId > 0 ? selectedPumpId : null, cancellationToken);
        var nozzlesTask = selectedPumpId > 0
            ? apiClient.GetNozzlesAsync(token, ownerId, selectedPumpId, cancellationToken)
            : Task.FromResult<IReadOnlyList<ApiNozzleDto>>(Array.Empty<ApiNozzleDto>());

        await Task.WhenAll(shiftsTask, salesTask, expensesTask, outstandingTask, tanksTask, productsTask, nozzlesTask);

        var shifts = shiftsTask.Result;
        var openShifts = shifts
            .Where(x => string.Equals(x.Status, "OPEN", StringComparison.OrdinalIgnoreCase))
            .OrderByDescending(x => x.Id)
            .ToList();
        var sales = salesTask.Result.Items;
        var expenses = expensesTask.Result;
        var outstanding = outstandingTask.Result;
        var allTanks = tanksTask.Result.Items;
        var products = productsTask.Result;
        var nozzles = nozzlesTask.Result;
        // Naye pump par har tank 0 hota hai kyunki opening stock daala hi nahi gaya —
        // us par "Low Tank Stock" ka laal alarm dena galat hai aur daraawna bhi.
        //
        // Lekin sirf "kisi tank me stock hai" dekhna bhi galat hota: jo pump SACH ME
        // chalte-chalte khaali ho gaya, uska alarm gayab ho jaata — aur wahi to asli
        // aapatkaal hai. Isliye: ek baar shift khul gayi = pump chaalu hai = alarm
        // sach hai, chahe tank 0 ho.
        var pumpIsRunning = shifts.Count > 0 || allTanks.Any(t => t.CurrentStock > 0);

        var lowStockTanks = pumpIsRunning
            ? allTanks.Where(t => t.IsActive && t.CurrentStock <= t.SafeFillLevel).ToList()
            : new List<ApiTankDto>();

        var startOnly = targetMonthStart.Date;
        var endOnly = targetMonthEnd.Date;

        var monthSales = sales.Where(x => x.BillDateTime.Date >= startOnly && x.BillDateTime.Date <= endOnly).ToList();
        var monthExpenses = expenses.Where(x => x.TxnDateTime.Date >= startOnly && x.TxnDateTime.Date <= endOnly).ToList();
        
        var targetStartDay = DateOnly.FromDateTime(startOnly);
        var targetEndDay = DateOnly.FromDateTime(endOnly);
        var monthShifts = shifts.Where(x => x.ShiftDate >= targetStartDay && x.ShiftDate <= targetEndDay && string.Equals(x.Status, "CLOSED", StringComparison.OrdinalIgnoreCase)).ToList();

        // ── Sales ka total nikaalte waqt DOUBLE COUNTING se bachna hai ──
        // Band ho chuki shift ka meter reading hi us shift ka asli total hai — jo receipt
        // (Sales page se) usi shift me bani thi, wo litre meter me pehle se gine ja chuke
        // hain. Pehle yahan dono ko seedha jod diya jaata tha, isliye ek hi ₹4,780 ki sale
        // dashboard par ₹9,560 dikhti thi. Ab: band shift ka meter + sirf wo receipt jo
        // kisi band shift me nahi hai (khuli shift ya bina shift wali entry).
        var closedShiftIds = monthShifts.Select(x => x.Id).ToHashSet();
        var receiptsOutsideClosedShifts = monthSales.Where(x => !closedShiftIds.Contains(x.ShiftId)).ToList();

        var todayOnly = DateOnly.FromDateTime(today);
        var todayClosedShiftAmount = monthShifts.Where(x => x.ShiftDate == todayOnly).Sum(x => x.TotalSoldAmount);

        // ── "Kaun se din ki entry chhoot gayi" ──────────────────────────────────
        // Pehle ye sirf pichhle 15 din dekhta tha, aur hamesha AAJ se peeche —
        // yaani upar se August chuno to bhi September ke din dikhte the. Ab ye
        // CHUNE HUE MAHINE ke saare khaali din dikhata hai, isliye 20-25 din ki
        // entry chhooti ho to bhi poori list milti hai (mahina badal kar purane
        // mahine ki bhi).
        var shiftDates = shifts.Select(x => x.ShiftDate).ToHashSet();
        var saleDates = sales.Select(x => DateOnly.FromDateTime(x.BillDateTime.Date)).ToHashSet();

        // Software se pehle ke din "chhoote" nahi hain — un dinon ka hisaab is
        // system me tha hi nahi. Isliye sabse pehli entry se pehle kuch mat dikhao.
        DateOnly? firstEverEntry = null;
        if (shiftDates.Count > 0 || saleDates.Count > 0)
        {
            var candidates = shiftDates.Concat(saleDates);
            firstEverEntry = candidates.Min();
        }

        var missingDays = new List<MissingEntryDay>();
        if (firstEverEntry is not null)
        {
            var scanFrom = targetStartDay > firstEverEntry.Value ? targetStartDay : firstEverEntry.Value;

            // Aaj ka din chhod dete hain (abhi chal raha hai), aur aane wale din
            // to bharne ka sawaal hi nahi. Purana mahina ho to uske aakhir tak.
            var yesterday = DateOnly.FromDateTime(today.AddDays(-1));
            var scanTo = targetEndDay < yesterday ? targetEndDay : yesterday;

            for (var day = scanFrom; day <= scanTo; day = day.AddDays(1))
            {
                var hasShift = shiftDates.Contains(day);
                var hasSale = saleDates.Contains(day);
                if (!hasShift && !hasSale)
                {
                    missingDays.Add(new MissingEntryDay(day, hasShift, hasSale));
                }
            }
        }

        var todayReceiptAmount = receiptsOutsideClosedShifts
            .Where(x => x.BillDateTime.Date == today)
            .Sum(x => x.TotalAmount);

        // ── Setup kahan tak hua ──────────────────────────────────────────────
        // Naya pump pehle din kya kare — iska raasta. Sab ho jaane par ye panel
        // apne aap gayab ho jaata hai (IsComplete).
        var fuelProducts = products.Where(x => x.CurrentRate > 0).ToList();
        // Sirf CNG / charging wale pump par tank hota hi nahi (gas pipeline se aati hai) - tank aur
        // opening stock ke kadam wahan apne aap poore maano, warna checklist kabhi khatam nahi hoti.
        var needsTank = products.Count == 0
            || products.Any(p => PPMS.Client.Web.Services.ProductUnit.TracksStock(p.Category));
        var setup = new SetupStatus
        {
            HasProducts     = products.Count > 0,
            HasRates        = fuelProducts.Count > 0,
            HasTanks        = !needsTank || allTanks.Count > 0,
            HasNozzles      = nozzles.Count > 0,
            HasOpeningStock = !needsTank || allTanks.Any(t => t.CurrentStock > 0),
            HasAnyShift     = shifts.Count > 0
        };

        var model = new DashboardViewModel
        {
            OwnerId = ownerId,
            PumpId = selectedPumpId,
            PumpName = pumps.FirstOrDefault(x => x.Id == selectedPumpId)?.Name ?? "All Pumps",
            Pumps = pumps,
            TotalSalesAmount = receiptsOutsideClosedShifts.Sum(x => x.TotalAmount) + monthShifts.Sum(x => x.TotalSoldAmount),
            TodaySalesAmount = todayReceiptAmount + todayClosedShiftAmount,
            TotalExpenseAmount = monthExpenses.Sum(x => x.Amount),
            TodayExpenseAmount = monthExpenses.Where(x => x.TxnDateTime.Date == today).Sum(x => x.Amount),
            OutstandingAmount = outstanding.Sum(x => x.CurrentBalance),
            OpenShiftCount = openShifts.Count,
            // In-charge ab employee hai (Section K), par purani shift me sirf
            // OperatorUserId bhara ho sakta hai. Dono id alag-alag table ki hain,
            // isliye seedhe mila nahi sakte — prefix laga kar ginte hain, warna
            // Employee 4 aur User 4 ek hi aadmi gine jaate.
            ActiveOperatorCount = openShifts
                .Select(x => x.OperatorEmployeeId is > 0
                    ? $"E{x.OperatorEmployeeId}"
                    : x.OperatorUserId is > 0 ? $"U{x.OperatorUserId}" : null)
                .Where(x => x is not null)
                .Distinct()
                .Count(),
            ActivePartyCount = outstanding.Count,
            OpenShifts = openShifts.Take(10).ToList(),
            RecentSales = sales
                .OrderByDescending(x => x.BillDateTime)
                .Take(10)
                .ToList(),
            TopOutstanding = outstanding
                .OrderByDescending(x => x.CurrentBalance)
                .Take(8)
                .ToList(),
            LowStockTanks = lowStockTanks,
            AllTanks = allTanks.Where(t => t.IsActive).ToList(),
            MissingDays = missingDays,
            Setup = setup,
            SelectedMonthYear = selectedMonthYearVal,
            SelectedMonthLabel = selectedMonthLabel,
            AvailableMonths = availableMonths
        };

        return View(model);
    }

    public IActionResult Privacy()
    {
        return View();
    }

    [ResponseCache(Duration = 0, Location = ResponseCacheLocation.None, NoStore = true)]
    public IActionResult Error()
    {
        return View(new ErrorViewModel { RequestId = Activity.Current?.Id ?? HttpContext.TraceIdentifier });
    }

    private long GetOwnerId()
    {
        var ownerIdString = HttpContext.Session.GetString("owner_id");
        return long.TryParse(ownerIdString, out var ownerId) ? ownerId : 1;
    }
}
