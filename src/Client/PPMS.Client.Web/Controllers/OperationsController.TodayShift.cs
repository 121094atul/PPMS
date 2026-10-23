using System.Text.Json;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.Localization;
using PPMS.Client.Web.Models;
using PPMS.Client.Web.Services;

namespace PPMS.Client.Web.Controllers;

/// <summary>
/// "Aaj ki shift" — poori shift ek screen par. Naya API kuch nahi: wahi purane
/// endpoint (open, collection, expense, close, dip) ek kram me chalte hain.
/// Dekho Models/TodayShiftViewModel.cs.
/// </summary>
public partial class OperationsController
{
    private const string TodayShiftClosedKey = "TodayShiftClosed";

    private IStringLocalizer<SharedResource> Loc =>
        HttpContext.RequestServices.GetRequiredService<IStringLocalizer<SharedResource>>();

    [HttpGet]
    public async Task<IActionResult> TodayShift(long? pumpId, DateOnly? date, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null) return RedirectToAction("Login", "Account");

        ViewData["Title"] = "Today's Shift";
        var ownerId = GetOwnerId();
        var today = DateOnly.FromDateTime(DateTime.Today);

        var pumps = await Api.GetPumpsAsync(token, ownerId, cancellationToken);
        var pump = pumps.FirstOrDefault(p => p.Id == pumpId) ?? pumps.FirstOrDefault();

        var model = new TodayShiftViewModel
        {
            Pumps = pumps,
            Today = today,
            Message = TempData["TodayShiftMessage"] as string,
            IsError = TempData["TodayShiftIsError"] is true,
            KeepInDrawer = CashKeptInDrawer
        };

        if (TempData[TodayShiftClosedKey] is string closedJson)
        {
            try { model.JustClosed = JsonSerializer.Deserialize<TodayShiftClosedInfo>(closedJson); }
            catch (JsonException) { /* sirf dikhane ke liye tha - na mile to koi baat nahi */ }
        }

        if (pump is null) return View(model);
        model.PumpId = pump.Id;
        model.PumpName = pump.Name;

        // Ek pump par ek hi shift khuli reh sakti hai (sp_Shift_Open rokta hai).
        // List Id ke ulte kram me aati hai — 300 me khuli shift aur aakhri din dono mil jaate hain.
        var shifts = await Api.GetShiftsAsync(token, ownerId, pump.Id, null, null, 300, cancellationToken);
        model.Shift = shifts
            .Where(s => string.Equals(s.Status, "OPEN", StringComparison.OrdinalIgnoreCase))
            .OrderByDescending(s => s.Id)
            .FirstOrDefault();
        model.LastShift = shifts
            .OrderByDescending(s => s.ShiftDate).ThenByDescending(s => s.Id)
            .FirstOrDefault();

        if (model.Shift is null)
        {
            await FillTodayShiftStartAsync(model, shifts, date, token, ownerId, cancellationToken);
        }
        else
        {
            await FillTodayShiftRunAsync(model, token, ownerId, cancellationToken);
        }

        return View(model);
    }

    private async Task FillTodayShiftStartAsync(TodayShiftViewModel model, IReadOnlyList<ApiShiftDto> shifts,
        DateOnly? date, string token, long ownerId, CancellationToken cancellationToken)
    {
        // Is pump par din kai din baad register se bhare jaate hain (live par 2-6 din
        // baad). Isliye "aaj" nahi, AAKHRI BHARE DIN KA AGLA din sujhate hain.
        var suggested = model.LastShift is null ? model.Today : model.LastShift.ShiftDate.AddDays(1);
        if (suggested > model.Today) suggested = model.Today;

        var day = date ?? suggested;
        if (day > model.Today)
        {
            model.Message = Loc["You cannot start a shift for a future date."].Value;
            model.IsError = true;
            day = suggested;
        }

        var prev = shifts.Where(s => s.ShiftDate < day).Select(s => (DateOnly?)s.ShiftDate).DefaultIfEmpty().Max();
        if (prev is DateOnly p && day.DayNumber - p.DayNumber > 1)
        {
            model.GapDays = day.DayNumber - p.DayNumber - 1;
            model.GapFrom = p.AddDays(1);
        }
        model.LaterDate = shifts.Where(s => s.ShiftDate > day).Select(s => (DateOnly?)s.ShiftDate).DefaultIfEmpty().Min();

        var sameDay = shifts.Where(s => s.ShiftDate == day).Select(s => s.ShiftCode).ToList();
        model.SameDayCodes = sameDay.Count > 0 ? string.Join(", ", sameDay) : null;

        var nozzles = (await Api.GetNozzlesAsync(token, ownerId, model.PumpId, cancellationToken))
            .Where(n => n.IsActive)
            .ToList();
        var last = await Api.GetLastNozzleReadingsAsync(token, model.PumpId, day, cancellationToken);
        var employees = (await Api.GetEmployeesAsync(token, ownerId, model.PumpId, cancellationToken))
            .Where(e => e.IsActive)
            .OrderBy(e => e.FullName)
            .ToList();

        // In-charge aksar wahi rehta hai — pichhli shift wala pehle se chuna.
        var lastOperator = model.LastShift?.OperatorEmployeeId;

        // Galle me shuru ka nakad = jitna har shift ke baad bachta hai. Baaki shift band hote hi malik ko
        // chala jaata hai (Section AN), isliye pichhla ClosingCash nahi - wo purane din jud-jud kar crore ho gaya tha.
        // User ise badal sakta hai.
        model.SuggestedOpeningCash = CashKeptInDrawer;

        model.Employees = employees;
        model.Start = new TodayShiftStartForm
        {
            PumpId = model.PumpId,
            ShiftDate = day,
            OpeningCash = model.SuggestedOpeningCash,
            OperatorEmployeeId = employees.Any(e => e.Id == lastOperator) ? lastOperator : null,
            Readings = nozzles
                .OrderBy(n => n.NozzleCode)
                .Select(n => new TodayShiftOpeningRow
                {
                    NozzleId = n.Id,
                    ProductId = n.ProductId,
                    NozzleCode = n.NozzleCode,
                    ProductName = n.ProductName,
                    OpeningReading = last.FirstOrDefault(r => r.NozzleId == n.Id)?.ClosingReading ?? 0
                })
                .ToList()
        };
    }

    private async Task FillTodayShiftRunAsync(TodayShiftViewModel model, string token, long ownerId, CancellationToken cancellationToken)
    {
        var shift = model.Shift!;

        var readingsTask = Api.GetShiftNozzleReadingsAsync(token, shift.Id, cancellationToken);
        var lastTask = Api.GetLastNozzleReadingsAsync(token, model.PumpId, shift.ShiftDate, cancellationToken);
        var tanksTask = Api.GetShiftClosingDipsAsync(token, shift.Id, cancellationToken);
        var collectionTask = Api.GetShiftCollectionAsync(token, shift.Id, cancellationToken);
        var summaryTask = Api.GetShiftCollectionSummaryAsync(token, shift.Id, cancellationToken);
        var partiesTask = Api.GetAllPartiesAsync(token, ownerId, model.PumpId, cancellationToken);
        var headsTask = Api.GetExpenseHeadsAsync(token, ownerId, model.PumpId, cancellationToken);
        var expensesTask = GetShiftExpensesAsync(token, ownerId, model.PumpId, shift, cancellationToken);
        var productsTask = Api.GetProductsAsync(token, ownerId, model.PumpId, cancellationToken);
        var handoversTask = GetShiftHandoversAsync(token, ownerId, model.PumpId, shift, cancellationToken);
        await Task.WhenAll(readingsTask, lastTask, tanksTask, collectionTask, summaryTask, partiesTask, headsTask, expensesTask, productsTask, handoversTask);

        // Naam se ikai; do product ka naam ek ho to pehla (ek pump par aisa hota nahi).
        model.ProductUnits = productsTask.Result
            .GroupBy(p => p.Name)
            .ToDictionary(g => g.Key, g => g.First().Unit, StringComparer.OrdinalIgnoreCase);
        model.ProductIds = productsTask.Result
            .GroupBy(p => p.Name)
            .ToDictionary(g => g.Key, g => g.First().Id, StringComparer.OrdinalIgnoreCase);

        model.Nozzles = readingsTask.Result.OrderBy(r => r.NozzleCode).ToList();
        model.LastTesting = lastTask.Result.ToDictionary(r => r.NozzleId, r => r.TestingLoss);
        model.Tanks = tanksTask.Result;
        model.Collection = collectionTask.Result;
        model.Parties = partiesTask.Result.Where(p => p.IsActive).OrderBy(p => p.PartyName).ToList();
        model.ExpenseHeads = headsTask.Result.Where(h => h.IsActive).OrderBy(h => h.HeadName).ToList();
        model.Expenses = expensesTask.Result;
        model.Handovers = handoversTask.Result;
        model.Cash = BuildCashParts(summaryTask.Result, model.Collection, shift.OpeningCash, model.Handovers);
        model.ToleranceRs = summaryTask.Result?.ToleranceRs is > 0 ? summaryTask.Result.ToleranceRs : 100;
    }

    /// <summary>
    /// Shift ke kharche. Kharche ki list tareekh se chhanti hai, isliye shift ke din
    /// ke aas-paas maang kar ShiftId se chhaant lete hain.
    /// </summary>
    private async Task<IReadOnlyList<ApiExpenseDto>> GetShiftExpensesAsync(string token, long ownerId, long pumpId, ApiShiftDto shift, CancellationToken cancellationToken)
    {
        var from = shift.ShiftDate.AddDays(-1).ToDateTime(TimeOnly.MinValue);
        var to = shift.ShiftDate.AddDays(1).ToDateTime(TimeOnly.MinValue);
        var page = await Api.GetPagedExpensesAsync(token, ownerId, pumpId, from, to, null, 1, 200, cancellationToken);
        return page.Items.Where(e => e.ShiftId == shift.Id).OrderBy(e => e.Id).ToList();
    }

    // Galle se nikala nakad Cashbook ke wahi do prakaar me jaata hai jo shift ka hisaab pehle se ginta hai
    // (OUT, BANK_DEPOSIT) — alag se kuch naya nahi. ReferenceNo ke "HANDOVER-" se pehchaante hain, taaki
    // Cashbook se haath se daali OUT / BANK_DEPOSIT entry is screen ke "nikala hua" me na mil jaye.
    private const string HandoverOwnerRef = "HANDOVER-OWNER";
    private const string HandoverBankRef = "HANDOVER-BANK";

    /// <summary>Is shift me galle se nikala nakad. Cashbook list tareekh se chhanti hai, isliye shift ke din ke aas-paas maang kar ShiftId se chhaant lete hain.</summary>
    private async Task<IReadOnlyList<TodayShiftHandover>> GetShiftHandoversAsync(string token, long ownerId, long pumpId, ApiShiftDto shift, CancellationToken cancellationToken)
    {
        var from = shift.ShiftDate.AddDays(-1).ToDateTime(TimeOnly.MinValue);
        var to = shift.ShiftDate.AddDays(1).ToDateTime(TimeOnly.MinValue);
        var page = await Api.GetPagedCashTransactionsAsync(token, ownerId, pumpId, from, to, "HANDOVER-", 1, 200, cancellationToken);
        return page.Items
            .Where(t => t.ShiftId == shift.Id && t.ReferenceNo is not null && t.ReferenceNo.StartsWith("HANDOVER-", StringComparison.Ordinal))
            .OrderBy(t => t.Id)
            .Select(t => new TodayShiftHandover(
                t.Id,
                string.Equals(t.ReferenceNo, HandoverBankRef, StringComparison.Ordinal) ? "BANK" : "OWNER",
                t.Amount,
                t.Narration))
            .ToList();
    }

    /// <summary>
    /// Summary me is screen ka apna UPI / card / udhaar bhi juda hota hai, aur galle se nikala nakad bhi
    /// (OUT / BANK_DEPOSIT me). Screen ye sab khud jodti hai (likhte-likhte), isliye yahan se nikaal kar
    /// baaki hissa dete hain. Nikala nakad ginne ke BAAD nikalta hai, isliye "kitna aana chahiye" me nahi ghatta.
    /// </summary>
    private static TodayShiftCashParts BuildCashParts(ApiShiftCollectionSummaryDto? s, ApiShiftCollection c, decimal openingCash, IReadOnlyList<TodayShiftHandover> handovers)
    {
        var handedOwner = handovers.Where(h => h.Kind == "OWNER").Sum(h => h.Amount);
        var handedBank = handovers.Where(h => h.Kind == "BANK").Sum(h => h.Amount);

        if (s is null) return new TodayShiftCashParts { OpeningCash = openingCash, HandoverOwner = handedOwner, HandoverBank = handedBank };

        var ownCredit = c.Credits.Sum(x => x.Amount);
        return new TodayShiftCashParts
        {
            HandoverOwner = handedOwner,
            HandoverBank = handedBank,
            OpeningCash = s.OpeningCash,
            OtherCredit = Math.Max(0, s.TotalCreditSales - ownCredit),
            OtherDigital = Math.Max(0, s.TotalDigitalSales - c.UpiAmount - c.CardAmount),
            ReceiptsCash = s.PartyReceiptsCash,
            CashIn = s.CashIn,
            CashOut = Math.Max(0, s.CashOut - handedOwner),
            CashExpenses = s.TotalCashExpenses,
            BankDeposits = Math.Max(0, s.TotalBankDeposits - handedBank)
        };
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> StartTodayShift(TodayShiftStartForm start, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null) return RedirectToAction("Login", "Account");

        var ownerId = GetOwnerId();
        var today = DateOnly.FromDateTime(DateTime.Today);

        IActionResult Back(string message)
        {
            TempData["TodayShiftMessage"] = message;
            TempData["TodayShiftIsError"] = true;
            return RedirectToAction(nameof(TodayShift), new { pumpId = start.PumpId, date = start.ShiftDate.ToString("yyyy-MM-dd") });
        }

        if (start.PumpId <= 0) return Back(Loc["Please select a pump."].Value);
        if (start.ShiftDate > today) return Back(Loc["You cannot start a shift for a future date."].Value);

        var readings = (start.Readings ?? new List<TodayShiftOpeningRow>()).Where(r => r.NozzleId > 0).ToList();
        if (readings.Count == 0) return Back(Loc["This pump has no active nozzle. Add nozzles first."].Value);

        // Code aur opening cash wahi niyam jo Shifts page lagata hai: us din jo code
        // khaali ho (A, B, C...), aur us din tak ki aakhri band shift ka closing cash.
        var shifts = await Api.GetShiftsAsync(token, ownerId, start.PumpId,
            start.ShiftDate.AddDays(-60), start.ShiftDate, 500, cancellationToken);
        var usedCodes = shifts.Where(s => s.ShiftDate == start.ShiftDate)
            .Select(s => s.ShiftCode?.Trim().ToUpperInvariant())
            .ToHashSet();
        var code = new[] { "A", "B", "C", "D", "E", "F" }.FirstOrDefault(c => !usedCodes.Contains(c)) ?? $"S{usedCodes.Count + 1}";
        var lastClosing = shifts
            .Where(s => s.Status == "CLOSED" && s.ShiftDate <= start.ShiftDate)
            .OrderByDescending(s => s.ShiftDate).ThenByDescending(s => s.Id)
            .FirstOrDefault()?.ClosingCash ?? 0;

        // User ne galle ka asli nakad alag likha ho to wahi. Pichhla closing aur ye farak shift ke Notes me
        // rehta hai - baad me poochhne par saaf dikhe.
        var openingCash = start.OpeningCash is >= 0 ? start.OpeningCash.Value : CashKeptInDrawer;
        var openingNote = OpeningCashNote(openingCash, lastClosing);

        var operatorId = start.OperatorEmployeeId is > 0 ? start.OperatorEmployeeId : null;
        var result = await Api.OpenShiftAsync(token,
            new ApiOpenShiftRequest(
                ownerId,
                start.PumpId,
                operatorId is null ? GetUserId() : null,
                start.ShiftDate,
                code,
                openingCash,
                openingNote,
                readings.Select(r => new ApiShiftNozzleOpenReading(r.NozzleId, r.ProductId, r.OpeningReading)).ToList(),
                operatorId,
                start.AllowMeterGap),
            cancellationToken);

        if (!result.Success) return Back(result.ErrorMessage ?? Loc["Could not start the shift."].Value);

        return RedirectToAction(nameof(TodayShift), new { pumpId = start.PumpId });
    }

    /// <summary>
    /// UPI / card / udhaar ki parchiyan — beech me bhi save hoti hain (paisa wale kadam
    /// se aage badhte hi), taaki phone band ho jaaye to bhi server par rahein.
    /// Save hamesha poora hata kar dobara banata hai, isliye kitni bhi baar chale.
    /// </summary>
    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> SaveTodayShiftMoney([FromBody] TodayShiftMoneyInput input, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null) return Unauthorized();

        var check = ValidateMoney(input.Upi, input.Card, input.Slips);
        if (check is not null) return Json(new { success = false, message = check });

        var ownerId = GetOwnerId();
        var shift = await FindPumpShiftAsync(token, ownerId, input.PumpId, input.ShiftId, cancellationToken);
        if (shift is null) return Json(new { success = false, message = Loc["That shift was not found."].Value });

        var save = await Api.SaveShiftCollectionAsync(token,
            new ApiSaveShiftCollectionRequest(input.ShiftId, input.Upi, input.Card, ToCreditLines(input.Slips)),
            cancellationToken);
        if (!save.Success) return Json(new { success = false, message = save.ErrorMessage });

        var cash = await ReloadCashPartsAsync(token, ownerId, shift, cancellationToken);
        return Json(new { success = true, cash });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> AddTodayShiftExpense([FromBody] TodayShiftExpenseInput input, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null) return Unauthorized();
        if (input.ExpenseHeadId <= 0 || input.Amount <= 0)
        {
            return Json(new { success = false, message = Loc["Pick the expense type and enter the amount."].Value });
        }

        var ownerId = GetOwnerId();
        var shift = await FindPumpShiftAsync(token, ownerId, input.PumpId, input.ShiftId, cancellationToken);
        if (shift is null) return Json(new { success = false, message = Loc["That shift was not found."].Value });

        // Purana din bhar rahe hain to kharcha bhi usi din ka — warna "aaj" ki
        // tareekh par chala jaata aur us din ke kharche me dikhta hi nahi.
        DateTime? when = shift.ShiftDate == DateOnly.FromDateTime(DateTime.Today)
            ? null
            : shift.ShiftDate.ToDateTime(new TimeOnly(12, 0));

        var save = await Api.SaveExpenseAsync(token,
            new ApiSaveExpenseRequest(ownerId, input.PumpId, input.ShiftId, input.ExpenseHeadId, input.Amount,
                "CASH", null, string.IsNullOrWhiteSpace(input.Narration) ? null : input.Narration.Trim(), when),
            cancellationToken);
        if (!save.Success) return Json(new { success = false, message = save.ErrorMessage });

        return Json(await ExpenseStateAsync(token, ownerId, input.PumpId, shift, cancellationToken));
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> DeleteTodayShiftExpense([FromBody] TodayShiftExpenseDeleteInput input, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null) return Unauthorized();

        var ownerId = GetOwnerId();
        var shift = await FindPumpShiftAsync(token, ownerId, input.PumpId, input.ShiftId, cancellationToken);
        if (shift is null) return Json(new { success = false, message = Loc["That shift was not found."].Value });

        // Sirf isi shift ka kharcha yahan se mite — koi aur id bhej de to nahi.
        var mine = await GetShiftExpensesAsync(token, ownerId, input.PumpId, shift, cancellationToken);
        if (mine.All(e => e.Id != input.Id))
        {
            return Json(new { success = false, message = Loc["That expense is not part of this shift."].Value });
        }

        var del = await Api.DeleteExpenseAsync(token, input.Id, cancellationToken);
        if (!del.Success) return Json(new { success = false, message = del.ErrorMessage });

        return Json(await ExpenseStateAsync(token, ownerId, input.PumpId, shift, cancellationToken));
    }

    /// <summary>Galle se nakad nikala: malik ko diya (Cashbook OUT) ya bank me jama (BANK_DEPOSIT). Turant server par.</summary>
    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> AddTodayShiftHandover([FromBody] TodayShiftHandoverInput input, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null) return Unauthorized();

        var isBank = string.Equals(input.Kind, "BANK", StringComparison.OrdinalIgnoreCase);
        if (!isBank && !string.Equals(input.Kind, "OWNER", StringComparison.OrdinalIgnoreCase))
        {
            return Json(new { success = false, message = Loc["Pick who the cash was given to."].Value });
        }
        if (input.Amount <= 0)
        {
            return Json(new { success = false, message = Loc["Enter the amount."].Value });
        }

        var ownerId = GetOwnerId();
        var shift = await FindPumpShiftAsync(token, ownerId, input.PumpId, input.ShiftId, cancellationToken);
        if (shift is null) return Json(new { success = false, message = Loc["That shift was not found."].Value });
        if (!string.Equals(shift.Status, "OPEN", StringComparison.OrdinalIgnoreCase))
        {
            return Json(new { success = false, message = Loc["This shift is already closed."].Value });
        }

        // Purana din bhar rahe hain to entry bhi usi din ki (kharche jaisa), warna Cashbook me "aaj" par dikhti.
        DateTime? when = shift.ShiftDate == DateOnly.FromDateTime(DateTime.Today)
            ? null
            : shift.ShiftDate.ToDateTime(new TimeOnly(12, 0));

        var label = isBank ? "Cash deposited in bank" : "Cash given to owner";
        var note = string.IsNullOrWhiteSpace(input.Note) ? label : $"{label} - {input.Note.Trim()}";
        var save = await Api.SaveCashTransactionAsync(token,
            new ApiSaveCashTransactionRequest(
                ownerId, input.PumpId, input.ShiftId,
                isBank ? "BANK_DEPOSIT" : "OUT",
                input.Amount,
                isBank ? HandoverBankRef : HandoverOwnerRef,
                note.Length > 240 ? note[..240] : note,
                when),
            cancellationToken);
        if (!save.Success) return Json(new { success = false, message = save.ErrorMessage });

        return Json(await HandoverStateAsync(token, ownerId, shift, cancellationToken));
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> DeleteTodayShiftHandover([FromBody] TodayShiftExpenseDeleteInput input, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null) return Unauthorized();

        var ownerId = GetOwnerId();
        var shift = await FindPumpShiftAsync(token, ownerId, input.PumpId, input.ShiftId, cancellationToken);
        if (shift is null) return Json(new { success = false, message = Loc["That shift was not found."].Value });
        if (!string.Equals(shift.Status, "OPEN", StringComparison.OrdinalIgnoreCase))
        {
            return Json(new { success = false, message = Loc["This shift is already closed."].Value });
        }

        // Sirf isi shift ki is screen se bani entry yahan se mite — Cashbook ki haath se daali entry ya koi aur id nahi.
        var mine = await GetShiftHandoversAsync(token, ownerId, input.PumpId, shift, cancellationToken);
        if (mine.All(h => h.Id != input.Id))
        {
            return Json(new { success = false, message = Loc["That entry is not part of this shift."].Value });
        }

        var del = await Api.DeleteCashTransactionAsync(token, input.Id, cancellationToken);
        if (!del.Success) return Json(new { success = false, message = del.ErrorMessage });

        return Json(await HandoverStateAsync(token, ownerId, shift, cancellationToken));
    }

    /// <summary>
    /// Shift band. Kram jaanbujh kar:
    ///   1. paisa (UPI / card / udhaar) — taaki band hote waqt ka "expected cash" sahi bane
    ///   2. shift band (reading, testing, closing cash = opening + aaj ka cash)
    ///   3. tank dip — band hone ke BAAD hi (Section AB: book stock me isi shift ki bikri ghatni chahiye)
    /// 1 fail ho to kuch band nahi hota. 1 dobara chal sakta hai (poora badal kar save karta hai).
    /// </summary>
    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> FinishTodayShift([FromBody] TodayShiftFinishInput input, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null) return Unauthorized();

        var ownerId = GetOwnerId();
        var shift = await FindPumpShiftAsync(token, ownerId, input.PumpId, input.ShiftId, cancellationToken);
        if (shift is null) return Json(new { success = false, message = Loc["That shift was not found."].Value });
        if (!string.Equals(shift.Status, "OPEN", StringComparison.OrdinalIgnoreCase))
        {
            return Json(new { success = false, message = Loc["This shift is already closed."].Value });
        }

        var readings = (input.Readings ?? new List<TodayShiftReadingInput>()).Where(r => r.NozzleId > 0).ToList();
        if (readings.Count == 0 || input.CashToday < 0)
        {
            return Json(new { success = false, message = Loc["Fill the closing reading of every nozzle."].Value });
        }

        // Closing < opening ko SP "meter ghoom gaya" (rollover) maan leta hai aur lakhon
        // litre bana deta hai. Purana Close Shift form ise rokta tha — yahan bhi, server par.
        var current = await Api.GetShiftNozzleReadingsAsync(token, shift.Id, cancellationToken);
        if (current.Any(c => readings.All(r => r.NozzleId != c.NozzleId)))
        {
            return Json(new { success = false, message = Loc["Fill the closing reading of every nozzle."].Value });
        }
        var less = current.FirstOrDefault(c => readings.Any(r => r.NozzleId == c.NozzleId && r.ClosingReading < c.OpeningReading));
        if (less is not null)
        {
            return Json(new { success = false, message = $"{less.NozzleCode}: {Loc["Closing is less than opening."].Value}" });
        }

        var check = ValidateMoney(input.Upi, input.Card, input.Slips);
        if (check is not null) return Json(new { success = false, message = check });

        // Galle me nakad = shuru ka + aaj ginaa hua - malik ko diya - bank me jama. Yahi ClosingCash bhejte hain;
        // sp_Shift_Close isme se CashKeptInDrawer chhod kar baaki "malik ko diya" likhta hai (Section AN).
        // Server khud DB ki entry se jodta hai — screen ka bheja hua jod nahi maanta.
        var handovers = await GetShiftHandoversAsync(token, ownerId, input.PumpId, shift, cancellationToken);
        var handedOwner = handovers.Where(h => h.Kind == "OWNER").Sum(h => h.Amount);
        var handedBank = handovers.Where(h => h.Kind == "BANK").Sum(h => h.Amount);
        var closingCash = shift.OpeningCash + input.CashToday - handedOwner - handedBank;
        if (closingCash < 0)
        {
            return Json(new { success = false, message = Loc["The cash handed over is more than the cash in the drawer."].Value });
        }

        var money = await Api.SaveShiftCollectionAsync(token,
            new ApiSaveShiftCollectionRequest(shift.Id, input.Upi, input.Card, ToCreditLines(input.Slips)),
            cancellationToken);
        if (!money.Success) return Json(new { success = false, message = money.ErrorMessage });

        var close = await Api.CloseShiftAsync(token, shift.Id,
            new ApiCloseShiftRequest(
                shift.Id,
                closingCash,
                string.IsNullOrWhiteSpace(input.Notes) ? null : input.Notes.Trim(),
                readings.Select(r => new ApiShiftNozzleCloseReading(r.NozzleId, r.ClosingReading, r.TestingLoss)).ToList()),
            cancellationToken);
        if (!close.Success) return Json(new { success = false, message = close.ErrorMessage });

        string? dipNote = null;
        var dips = (input.Dips ?? new List<TodayShiftDipInput>())
            .Where(d => d.TankId > 0 && (d.ActualStock ?? 0) > 0)
            .Select(d => new ApiShiftClosingDipInput(d.TankId, d.DipCm, d.ActualStock!.Value))
            .ToList();
        if (dips.Count > 0)
        {
            var dipResult = await Api.SaveShiftClosingDipsAsync(token, shift.Id, new ApiSaveShiftClosingDipsRequest(dips), cancellationToken);
            dipNote = dipResult.Success
                ? string.Join(", ", dipResult.Saved.Select(x => $"{x.TankName}: {(x.Variance > 0 ? "+" : "")}{x.Variance:0.##} L"))
                // Shift band ho chuki hai - use ulta nahi karte. Bas saaf batao.
                : Loc["But the dip was not saved"].Value + ": " + dipResult.ErrorMessage;
        }

        var s = await Api.GetShiftCollectionSummaryAsync(token, shift.Id, cancellationToken);

        // Band hote hi SP ne baaki nakad "malik ko diya" likh diya (Section AN) - wo bhi ab is shift ka nikala hua hai.
        var handedAfter = await GetShiftHandoversAsync(token, ownerId, input.PumpId, shift, cancellationToken);
        handedOwner = handedAfter.Where(h => h.Kind == "OWNER").Sum(h => h.Amount);
        handedBank = handedAfter.Where(h => h.Kind == "BANK").Sum(h => h.Amount);

        // Matra ikai ke hisaab se — CNG ke kg aur petrol-diesel ke litre ek me nahi jodte.
        var soldRows = await Api.GetShiftNozzleReadingsAsync(token, shift.Id, cancellationToken);
        var unitByProduct = (await Api.GetProductsAsync(token, ownerId, input.PumpId, cancellationToken))
            .GroupBy(p => p.Name)
            .ToDictionary(g => g.Key, g => g.First().Unit, StringComparer.OrdinalIgnoreCase);
        var qtyText = string.Join(" + ", soldRows
            .GroupBy(r => UnitAbbr(unitByProduct.TryGetValue(r.ProductName, out var u) ? u : null))
            .Select(g => $"{g.Sum(r => r.SoldQty):N2} {g.Key}"));

        var info = new TodayShiftClosedInfo
        {
            ShiftId = shift.Id,
            Label = $"{shift.ShiftDate:dd MMM yyyy} · {Loc["Shift"].Value} {shift.ShiftNo}",
            MeterSale = s?.TotalMeterSale ?? 0,
            MeterQty = s?.TotalMeterQty ?? 0,
            QtyText = qtyText,
            // Summary ka expected nikala hua nakad pehle hi ghata chuka hai; ginne se pehle wala (kitna gina jaana
            // chahiye) wapas jodkar. Fark = ginaa hua - itna, yani nikalne se bilkul alag.
            CashExpectedToday = (s?.ExpectedCash ?? 0) - (s?.OpeningCash ?? 0) + handedOwner + handedBank,
            CashToday = input.CashToday,
            HandedOwner = handedOwner,
            HandedBank = handedBank,
            LeftInDrawer = shift.OpeningCash + input.CashToday - handedOwner - handedBank,
            ShortExcess = s?.ShortExcess ?? 0,
            ToleranceRs = s?.ToleranceRs is > 0 ? s.ToleranceRs : 100,
            DipNote = dipNote
        };
        TempData[TodayShiftClosedKey] = JsonSerializer.Serialize(info);

        return Json(new { success = true, redirect = Url.Action(nameof(TodayShift), new { pumpId = input.PumpId }) });
    }

    /// <summary>
    /// Ek jaisi udhaar (Section AQ4): wahi party, wahi din, wahi rakam pehle se darj ho to lautata hai.
    /// Aaj ki shift / Collection (ShiftId) aur Party Ledger (EntryDate) teeno yahi bulate hain. Sirf
    /// chetavni - kuch rokta nahi; jaanch na ho paaye to khaali list.
    /// </summary>
    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> CheckCreditDuplicates([FromBody] CreditDuplicateCheckInput input, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null) return Unauthorized();

        var lines = (input.Lines ?? new List<CreditDuplicateLineInput>())
            .Where(l => l.PartyId > 0 && l.Amount > 0)
            .Select(l => new ApiCreditDuplicateLine(l.PartyId, l.Amount))
            .ToList();
        if (lines.Count == 0 || (input.ShiftId is not > 0 && input.EntryDate is null))
        {
            return Json(new { success = true, items = Array.Empty<object>() });
        }

        var found = await Api.FindCreditDuplicatesAsync(token,
            new ApiCreditDuplicateCheckRequest(input.ShiftId is > 0 ? input.ShiftId : null, input.EntryDate, lines),
            cancellationToken);
        return Json(new
        {
            success = true,
            items = found.Select(d => new { d.PartyId, d.PartyName, d.Amount, entryDate = d.EntryDate.ToString("dd MMM"), d.Notes })
        });
    }

    private string? ValidateMoney(decimal upi, decimal card, List<TodayShiftSlipInput>? slips)
    {
        if (upi < 0 || card < 0 || (slips ?? new()).Any(x => x.Amount < 0))
        {
            return Loc["Amount cannot be negative."].Value;
        }
        if ((slips ?? new()).Any(x => x.Amount > 0 && x.PartyId <= 0))
        {
            return Loc["Pick the party for every credit slip."].Value;
        }
        return null;
    }

    private static List<ApiShiftCollectionCreditLine> ToCreditLines(List<TodayShiftSlipInput>? slips) =>
        (slips ?? new List<TodayShiftSlipInput>())
            .Where(x => x.PartyId > 0 && x.Amount > 0)
            .Select(x => new ApiShiftCollectionCreditLine(
                x.PartyId, null, x.Amount,
                string.IsNullOrWhiteSpace(x.VehicleNo) ? null : x.VehicleNo.Trim().ToUpperInvariant(),
                string.IsNullOrWhiteSpace(x.SlipNote) ? null : x.SlipNote.Trim(),
                // Section AQ: tel tabhi jab matra likhi ho - warna sirf rakam wali parchi.
                x.ProductId is > 0 && x.Quantity is > 0 ? x.ProductId : null,
                x.ProductId is > 0 && x.Quantity is > 0 ? x.Quantity : null))
            .ToList();

    /// <summary>Us din tak ki aakhri band shift ka closing cash (galle me jitna chhoda gaya). Koi band shift na ho to null.</summary>
    private async Task<decimal?> LastClosingCashAsync(string token, long ownerId, long pumpId, DateOnly day, CancellationToken cancellationToken)
    {
        if (pumpId <= 0) return null;
        var shifts = await Api.GetShiftsAsync(token, ownerId, pumpId, day.AddDays(-60), day, 500, cancellationToken);
        return shifts
            .Where(s => string.Equals(s.Status, "CLOSED", StringComparison.OrdinalIgnoreCase) && s.ShiftDate <= day)
            .OrderByDescending(s => s.ShiftDate).ThenByDescending(s => s.Id)
            .FirstOrDefault()?.ClosingCash;
    }

    /// <summary>Opening pichhle closing se alag ho to shift ke Notes ke liye ek line, warna null.</summary>
    private static string? OpeningCashNote(decimal openingCash, decimal? lastClosing) =>
        lastClosing is decimal last && last != openingCash
            ? $"Opening cash {openingCash:N2} (last shift closed with {last:N2} in the drawer)"
            : null;

    /// <summary>Shift sirf usi pump ki honi chahiye jo screen bhej rahi hai. API apni taraf se owner bhi jaanchta hai.</summary>
    private async Task<ApiShiftDto?> FindPumpShiftAsync(string token, long ownerId, long pumpId, long shiftId, CancellationToken cancellationToken)
    {
        if (pumpId <= 0 || shiftId <= 0) return null;
        var shifts = await Api.GetShiftsAsync(token, ownerId, pumpId, null, null, 300, cancellationToken);
        return shifts.FirstOrDefault(s => s.Id == shiftId);
    }

    private async Task<TodayShiftCashParts> ReloadCashPartsAsync(string token, long ownerId, ApiShiftDto shift, CancellationToken cancellationToken)
    {
        var summaryTask = Api.GetShiftCollectionSummaryAsync(token, shift.Id, cancellationToken);
        var collectionTask = Api.GetShiftCollectionAsync(token, shift.Id, cancellationToken);
        var handoversTask = GetShiftHandoversAsync(token, ownerId, shift.PumpId, shift, cancellationToken);
        await Task.WhenAll(summaryTask, collectionTask, handoversTask);
        return BuildCashParts(summaryTask.Result, collectionTask.Result, summaryTask.Result?.OpeningCash ?? 0, handoversTask.Result);
    }

    private async Task<object> HandoverStateAsync(string token, long ownerId, ApiShiftDto shift, CancellationToken cancellationToken)
    {
        var listTask = GetShiftHandoversAsync(token, ownerId, shift.PumpId, shift, cancellationToken);
        var cashTask = ReloadCashPartsAsync(token, ownerId, shift, cancellationToken);
        await Task.WhenAll(listTask, cashTask);
        return new { success = true, handovers = listTask.Result, cash = cashTask.Result };
    }

    private async Task<object> ExpenseStateAsync(string token, long ownerId, long pumpId, ApiShiftDto shift, CancellationToken cancellationToken)
    {
        var listTask = GetShiftExpensesAsync(token, ownerId, pumpId, shift, cancellationToken);
        var cashTask = ReloadCashPartsAsync(token, ownerId, shift, cancellationToken);
        await Task.WhenAll(listTask, cashTask);
        return new
        {
            success = true,
            expenses = listTask.Result.Select(e => new { e.Id, e.ExpenseHeadName, e.Amount, e.Narration }),
            cash = cashTask.Result
        };
    }
}
