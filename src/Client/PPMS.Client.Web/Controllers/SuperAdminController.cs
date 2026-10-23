using Microsoft.AspNetCore.Mvc;
using PPMS.Client.Web.Models;
using PPMS.Client.Web.Services;

namespace PPMS.Client.Web.Controllers;

public class SuperAdminController(PPMSApiClient apiClient) : Controller
{
    private string GetAccessToken() => HttpContext.Session.GetString("access_token") ?? string.Empty;
    private bool IsSuperAdmin() => bool.TryParse(HttpContext.Session.GetString("is_super_admin"), out var b) && b;

    [HttpGet]
    public async Task<IActionResult> Index(CancellationToken cancellationToken)
    {
        if (!IsSuperAdmin())
        {
            return RedirectToAction("Index", "Home");
        }

        var token = GetAccessToken();
        var owners = await apiClient.GetOwnersAsync(token, cancellationToken);
        var requests = await apiClient.GetSubscriptionRequestsAsync(token, cancellationToken);
        ViewBag.SubscriptionRequests = requests;
        return View(owners);
    }

    [HttpGet]
    public IActionResult CreateTenant()
    {
        if (!IsSuperAdmin())
        {
            return RedirectToAction("Index", "Home");
        }
        return View(new ApiSaveOwnerRequest("", "", ""));
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> CreateTenant(ApiSaveOwnerRequest model, CancellationToken cancellationToken)
    {
        if (!IsSuperAdmin())
        {
            return RedirectToAction("Index", "Home");
        }

        if (string.IsNullOrWhiteSpace(model.Name) || string.IsNullOrWhiteSpace(model.AdminUsername) || string.IsNullOrWhiteSpace(model.AdminPassword))
        {
            ModelState.AddModelError("", "All fields are required.");
            return View(model);
        }

        var token = GetAccessToken();
        var success = await apiClient.SaveOwnerAsync(token, model, cancellationToken);
        if (success.Success)
        {
            return RedirectToAction("Index");
        }

        // Server ka asli sandesh dikhao — pehle sirf generic error milta tha.
        TempData["SuperAdminMessage"] = success.ErrorMessage ?? "Could not save the owner.";

        ModelState.AddModelError("", "Failed to create tenant. Ensure username is unique.");
        return View(model);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> ToggleStatus(long id, CancellationToken cancellationToken)
    {
        if (!IsSuperAdmin())
        {
            return RedirectToAction("Index", "Home");
        }

        var token = GetAccessToken();
        await apiClient.ToggleOwnerStatusAsync(token, id, cancellationToken);
        
        return RedirectToAction("Index");
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> ExtendTrial(long id, string newValidUpto, CancellationToken cancellationToken)
    {
        if (!IsSuperAdmin())
        {
            return RedirectToAction("Index", "Home");
        }

        if (DateTime.TryParse(newValidUpto, out var parsedDate))
        {
            var token = GetAccessToken();
            await apiClient.ExtendOwnerTrialAsync(token, id, parsedDate, cancellationToken);
        }
        
        return RedirectToAction("Index");
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> MarkSubscriptionDone(long id, CancellationToken cancellationToken)
    {
        if (!IsSuperAdmin())
        {
            return RedirectToAction("Index", "Home");
        }

        var token = GetAccessToken();
        await apiClient.MarkSubscriptionDoneAsync(token, id, cancellationToken);
        return RedirectToAction("Index");
    }

    /// <summary>Kisi tenant ke users - password reset ke liye modal me dikhte hain.</summary>
    [HttpGet]
    public async Task<IActionResult> TenantUsers(long ownerId, CancellationToken cancellationToken)
    {
        // Client side par bhi guard - API par SuperAdminOnly hai hi, lekin yahan
        // rok dene se aam user ko ye endpoint dikhta hi nahi.
        if (!IsSuperAdmin()) return Forbid();

        var users = await apiClient.GetTenantUsersAsync(GetAccessToken(), ownerId, cancellationToken);
        return Json(users);
    }

    /// <summary>
    /// Grahak ka phone aata hai "password bhool gaya" - pehle iske liye seedha DB
    /// kholni padti thi. API par SuperAdminOnly hai aur SP bhi khud jaanchti hai.
    /// </summary>
    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> ResetUserPassword([FromBody] ResetUserPasswordInput model, CancellationToken cancellationToken)
    {
        if (!IsSuperAdmin()) return Forbid();

        if (model is null || model.UserId <= 0 || string.IsNullOrWhiteSpace(model.NewPassword) || model.NewPassword.Length < 6)
        {
            return BadRequest();
        }

        var ok = await apiClient.AdminResetUserPasswordAsync(GetAccessToken(), model.UserId, model.NewPassword, cancellationToken);
        // Asli wajah JS tak pahunchani hai — wo use screen par dikhata hai.
        return ok.Success ? Ok() : BadRequest(ok.ErrorMessage ?? "Could not reset the password.");
    }

    // ================= Support ke number (Section AR) =================
    // Yahan daale number Login page, Manual, Shifts aur SMS sandesh me dikhte hain.

    public async Task<IActionResult> HelpNumbers([FromServices] SupportContactService support, CancellationToken cancellationToken)
    {
        if (!IsSuperAdmin()) return Forbid();
        ViewData["Title"] = "Support Numbers";

        support.Invalidate();   // hamesha taaza dikhao
        ViewBag.Message = TempData["HelpMessage"] as string;
        ViewBag.IsError = TempData["HelpIsError"] is true;
        return View(await support.GetAsync(cancellationToken));
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> HelpNumbers(string? phone1, string? phone2, string? phone3,
        [FromServices] SupportContactService support, CancellationToken cancellationToken)
    {
        if (!IsSuperAdmin()) return Forbid();

        var result = await apiClient.SaveSupportContactsAsync(GetAccessToken(),
            new ApiSupportContacts(phone1, phone2, phone3), cancellationToken);
        support.Invalidate();

        TempData["HelpMessage"] = result.Success ? "Support numbers saved." : (result.ErrorMessage ?? "Could not save the support numbers.");
        TempData["HelpIsError"] = !result.Success;
        return RedirectToAction(nameof(HelpNumbers));
    }

    // ================= Message credits (Section Q) =================
    // Aapka stock (Twilio se khareeda) aur owner ke recharge — dono yahin se.

    public async Task<IActionResult> Credits(CancellationToken cancellationToken)
    {
        if (!IsSuperAdmin()) return Forbid();
        ViewData["Title"] = "Message Credits";

        var token = GetAccessToken();
        var summary = await apiClient.GetPlatformCreditAsync(token, cancellationToken);
        var recharges = await apiClient.GetAllRechargesAsync(token, null, cancellationToken);

        // UPI/rate wallet endpoint se aate hain (wahi ek jagah rakhi hai).
        var wallet = await apiClient.GetWalletAsync(token, cancellationToken);

        return View(new PlatformCreditViewModel
        {
            Summary = summary,
            Recharges = recharges,
            UpiId = wallet?.UpiId,
            UpiName = wallet?.UpiName,
            PricePerCredit = wallet?.PricePerCredit,
            Message = TempData["CreditMessage"] as string,
            IsError = TempData["CreditIsError"] is true
        });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> SaveCreditSettings(string? upiId, string? upiName, decimal? pricePerCredit, CancellationToken cancellationToken)
    {
        if (!IsSuperAdmin()) return Forbid();

        var result = await apiClient.SaveCreditSettingsAsync(GetAccessToken(),
            new ApiSaveCreditSettingsRequest(upiId, upiName, pricePerCredit), cancellationToken);

        TempData["CreditMessage"] = result.Success ? "Settings saved." : (result.ErrorMessage ?? "Could not save the settings.");
        TempData["CreditIsError"] = !result.Success;
        return RedirectToAction(nameof(Credits));
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> AddPlatformCredit(decimal amountPaid, int creditsBought, string? provider, string? referenceNo, string? notes, CancellationToken cancellationToken)
    {
        if (!IsSuperAdmin()) return Forbid();

        var result = await apiClient.AddPlatformCreditAsync(GetAccessToken(),
            new ApiAddPlatformCreditRequest(amountPaid, creditsBought, provider, referenceNo, notes), cancellationToken);

        TempData["CreditMessage"] = result.Success
            ? $"Added {creditsBought} messages to your stock."
            : (result.ErrorMessage ?? "Could not record the purchase.");
        TempData["CreditIsError"] = !result.Success;
        return RedirectToAction(nameof(Credits));
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> ApproveRecharge(long id, CancellationToken cancellationToken)
    {
        if (!IsSuperAdmin()) return Forbid();

        var result = await apiClient.ApproveRechargeAsync(GetAccessToken(), id, null, cancellationToken);
        // Stock kam pade to server ka asli message aata hai ("Not enough platform
        // credit...") — wahi dikhate hain, generic error nahi.
        TempData["CreditMessage"] = result.Success ? "Recharge approved. Credits added." : (result.ErrorMessage ?? "Could not approve the recharge.");
        TempData["CreditIsError"] = !result.Success;
        return RedirectToAction(nameof(Credits));
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> RejectRecharge(long id, string? note, CancellationToken cancellationToken)
    {
        if (!IsSuperAdmin()) return Forbid();

        var result = await apiClient.RejectRechargeAsync(GetAccessToken(), id, note, cancellationToken);
        TempData["CreditMessage"] = result.Success ? "Recharge rejected." : (result.ErrorMessage ?? "Could not reject the recharge.");
        TempData["CreditIsError"] = !result.Success;
        return RedirectToAction(nameof(Credits));
    }

    // ================= Support console (Section Z) =================
    //
    // Grahak ka phone aata hai "galti se shift band ho gayi", "khaali shift
    // ban gayi" — ab tak in dono ka ek hi ilaaj tha: developer database me
    // ghuse. Ab ye screen se ho jaate hain.
    //
    // Dhyan: yahan ownerId FORM se aata hai, JWT se nahi — support wala kisi
    // bhi owner ka data theek karta hai. Isi liye har action par SuperAdmin ki
    // jaanch hai, aur API par bhi "SuperAdminOnly" policy lagi hai.

    [HttpGet]
    public async Task<IActionResult> Support(long? ownerId, long? pumpId, int? days, CancellationToken cancellationToken)
    {
        if (!IsSuperAdmin()) return Forbid();

        var token = GetAccessToken();
        var owners = await apiClient.GetOwnersAsync(token, cancellationToken);

        var model = new SupportConsoleViewModel
        {
            Owners = owners,
            SelectedOwnerId = ownerId ?? 0,
            SelectedPumpId = pumpId ?? 0,
            Days = days is >= 7 and <= 365 ? days.Value : 60,
            Message = TempData["SupportMessage"] as string,
            IsError = TempData["SupportIsError"] as bool? ?? false
        };

        if (model.SelectedOwnerId > 0)
        {
            model.Shifts = await apiClient.GetSupportShiftsAsync(
                token, model.SelectedOwnerId, model.SelectedPumpId, model.Days, cancellationToken);

            // Meter ki kadi — sirf dikhane ke liye, kuch badalta nahi.
            model.MeterChainGaps = await apiClient.GetSupportMeterChainAsync(
                token, model.SelectedOwnerId, model.SelectedPumpId, model.Days, cancellationToken);
        }

        return View(model);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> SupportReopenShift(long shiftId, long ownerId, long? pumpId, CancellationToken cancellationToken)
    {
        if (!IsSuperAdmin()) return Forbid();

        var result = await apiClient.ReopenShiftAsync(GetAccessToken(), shiftId, ownerId, cancellationToken);
        TempData["SupportMessage"] = result.Success
            ? $"Shift #{shiftId} reopened. The closing readings are cleared - ask the owner to enter them and close it again."
            : result.ErrorMessage;
        TempData["SupportIsError"] = !result.Success;

        return RedirectToAction(nameof(Support), new { ownerId, pumpId });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> SupportDeleteShift(long shiftId, long ownerId, long? pumpId, string? reason, CancellationToken cancellationToken)
    {
        if (!IsSuperAdmin()) return Forbid();

        var result = await apiClient.DeleteShiftAsync(GetAccessToken(), shiftId, ownerId, reason, cancellationToken);
        TempData["SupportMessage"] = result.Success
            ? $"Shift #{shiftId} deleted."
            : result.ErrorMessage;
        TempData["SupportIsError"] = !result.Success;

        return RedirectToAction(nameof(Support), new { ownerId, pumpId });
    }

    /// <summary>
    /// Har party ka bakaya dobara ginwana: purana baki + khaate ki line.
    ///
    /// Parties.CurrentBalance ek chalta hua jod hai. Kabhi koi entry haath se
    /// hati ho, ya purani gadbad rah gayi ho, to wo ledger se alag ho jaata hai
    /// aur Outstanding report galat dikhne lagti hai. Ye use sach par le aata hai.
    ///
    /// UpdatedParties = kitni party ka baki sach me badla (Section AF se). 0 ka
    /// matlab sab pehle se sahi tha — ye bhi saaf batana hai, warna "0 updated"
    /// padh kar lagta hai ki button chala hi nahi.
    /// </summary>
    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> SupportRecalculateParties(long ownerId, CancellationToken cancellationToken)
    {
        if (!IsSuperAdmin()) return Forbid();

        var result = await apiClient.RecalculatePartyBalancesAsync(GetAccessToken(), ownerId, cancellationToken);
        TempData["SupportMessage"] = result.Success
            ? (result.UpdatedParties == 0
                ? "Checked every party - all balances already match (opening balance + ledger). Nothing was changed."
                : $"Party balances recounted (opening balance + ledger) - {result.UpdatedParties} corrected.")
            : result.ErrorMessage;
        TempData["SupportIsError"] = !result.Success;

        return RedirectToAction(nameof(Support), new { ownerId });
    }
}

public sealed record ResetUserPasswordInput(long UserId, string NewPassword);
