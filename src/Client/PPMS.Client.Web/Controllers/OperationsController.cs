using Microsoft.AspNetCore.Mvc;
using PPMS.Client.Web.Filters;
using PPMS.Client.Web.Models;
using PPMS.Client.Web.Services;

namespace PPMS.Client.Web.Controllers;

[SessionAuthorize]
public partial class OperationsController(PPMSApiClient apiClient) : Controller
{
    /// <summary>
    /// Doosri partial file (OperationsController.TodayShift.cs) ke liye. Primary
    /// constructor ka parameter sirf isi file me dikhta hai.
    /// </summary>
    private PPMSApiClient Api => apiClient;

    /// <summary>Shift List me ek page par kitni shift dikhein.</summary>
    private const int ShiftPageSize = 10;

    /// <summary>
    /// Form ke bagal wali list (Sales, Purchase, Expenses, Cashbook, Stock Reconcile) me
    /// ek page par kitni line.
    ///
    /// Pehle 50 tha. Pager tabhi dikhta hai jab ek page se zyada ho — to 50 se kam line par
    /// "Previous / Next" aata hi nahi tha, aur list form se kai guna lambi chalti jaati thi
    /// (phone par har line ek card hai: 50 card). Owner ko laga paging lagi hi nahi.
    /// Shifts aur Dip pehle hi 10 par aa chuke hain.
    /// </summary>
    private const int ListPageSize = 10;

    [HttpGet]
    public async Task<IActionResult> Pumps(long? editId, CancellationToken cancellationToken)
    {
        ViewData["Title"] = "Pump Management";
        var model = await BuildPumpViewModelAsync(editId, cancellationToken);
        return View(model);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> SavePump(PumpManagementViewModel model, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null)
        {
            return RedirectToAction("Login", "Account");
        }

        if (string.IsNullOrWhiteSpace(model.Form.Name))
        {
            TempData["PumpMessage"] = "Pump name is required.";
            return RedirectToAction(nameof(Pumps));
        }

        var request = new ApiSavePumpRequest(
            model.Form.Id,
            model.Form.OwnerId,
            model.Form.Name.Trim(),
            model.Form.City,
            model.Form.Address,
            model.Form.ContactNo,
            model.Form.GSTIN?.Trim());

        var success = await apiClient.SavePumpAsync(token, request, cancellationToken);
        TempData["PumpMessage"] = success.Success ? "Pump saved successfully." : (success.ErrorMessage ?? "Unable to save pump.");
        return RedirectToAction(nameof(Pumps));
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> DeletePump(long id, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null) return RedirectToAction("Login", "Account");

        var result = await apiClient.DeletePumpAsync(token, id, cancellationToken);
        TempData["PumpMessage"] = result.Success ? "Pump deleted successfully." : result.ErrorMessage;
        return RedirectToAction(nameof(Pumps));
    }

    [HttpGet]
    public async Task<IActionResult> Nozzles(long? editId, long? pumpId, CancellationToken cancellationToken)
    {
        ViewData["Title"] = "Nozzle Management";
        var model = await BuildNozzleViewModelAsync(editId, pumpId, cancellationToken);
        return View(model);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> SaveNozzle(NozzleManagementViewModel model, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null)
        {
            return RedirectToAction("Login", "Account");
        }

        if (model.Form.PumpId <= 0 || model.Form.ProductId <= 0 || string.IsNullOrWhiteSpace(model.Form.NozzleCode))
        {
            TempData["NozzleMessage"] = "Pump, product and nozzle code are required.";
            return RedirectToAction(nameof(Nozzles), new { pumpId = model.Form.PumpId });
        }

        // Tank ke bina nozzle ka koi matlab nahi — bikne wala tel kisi tank se ghatna
        // hi chahiye. Pehle ye chhoot jaata tha aur galti bahut baad me pakdi jaati:
        // shift kholte waqt "Some nozzles have no tank set" aata tha, us page par
        // jahan galti hui hi nahi thi. SP me bhi rok hai (THROW 50063/50064), ye
        // sirf pehli deewar hai taaki message saaf mile.
        //
        // Sirf gas (CNG) / charging ko chhoot: unka tank hota hi nahi (Section AL).
        if (model.Form.TankId is null or 0)
        {
            var pumpProducts = await apiClient.GetProductsAsync(token, GetOwnerId(), model.Form.PumpId, cancellationToken);
            var chosen = pumpProducts.FirstOrDefault(p => p.Id == model.Form.ProductId);
            if (chosen is null || PPMS.Client.Web.Services.ProductUnit.TracksStock(chosen.Category))
            {
                TempData["NozzleMessage"] = "Please pick the tank this nozzle draws from. "
                    + "If the list is empty, add a tank for this product first.";
                return RedirectToAction(nameof(Nozzles), new { pumpId = model.Form.PumpId });
            }
        }

        var request = new ApiSaveNozzleRequest(
            model.Form.Id,
            model.Form.OwnerId,
            model.Form.PumpId,
            model.Form.ProductId,
            model.Form.NozzleCode.Trim().ToUpperInvariant(),
            model.Form.TankId);

        var success = await apiClient.SaveNozzleAsync(token, request, cancellationToken);
        TempData["NozzleMessage"] = success.Success ? "Nozzle saved successfully." : (success.ErrorMessage ?? "Unable to save nozzle.");
        return RedirectToAction(nameof(Nozzles), new { pumpId = model.Form.PumpId });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> DeleteNozzle(long id, long pumpId, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null) return RedirectToAction("Login", "Account");

        var result = await apiClient.DeleteNozzleAsync(token, id, cancellationToken);
        TempData["NozzleMessage"] = result.Success ? "Nozzle deleted successfully." : result.ErrorMessage;
        return RedirectToAction(nameof(Nozzles), new { pumpId });
    }

    [HttpGet]
    public async Task<IActionResult> Tanks(long? editId, long? pumpId, string? searchTerm, CancellationToken cancellationToken)
    {
        ViewData["Title"] = "Tank Management";
        var model = await BuildTankViewModelAsync(editId, pumpId, searchTerm, cancellationToken);
        return View(model);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> SaveTank(TankManagementViewModel model, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null)
        {
            return RedirectToAction("Login", "Account");
        }

        if (model.Form.PumpId <= 0 || model.Form.ProductId <= 0 || string.IsNullOrWhiteSpace(model.Form.Name))
        {
            TempData["TankMessage"] = "Pump, product and tank name are required.";
            return RedirectToAction(nameof(Tanks), new { pumpId = model.Form.PumpId });
        }

        var request = new ApiSaveTankRequest(
            model.Form.Id,
            model.Form.OwnerId,
            model.Form.PumpId,
            model.Form.Name.Trim(),
            model.Form.ProductId,
            model.Form.Capacity,
            model.Form.SafeFillLevel,
            model.Form.CurrentStock,
            model.Form.IsActive);

        var success = await apiClient.SaveTankAsync(token, request, cancellationToken);
        TempData["TankMessage"] = success.Success ? "Tank saved successfully." : (success.ErrorMessage ?? "Unable to save tank.");
        return RedirectToAction(nameof(Tanks), new { pumpId = model.Form.PumpId });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> DeleteTank(long id, long pumpId, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null) return RedirectToAction("Login", "Account");

        var result = await apiClient.DeleteTankAsync(token, id, cancellationToken);
        TempData["TankMessage"] = result.Success ? "Tank deleted successfully." : result.ErrorMessage;
        return RedirectToAction(nameof(Tanks), new { pumpId });
    }

    [HttpGet]
    public async Task<IActionResult> Parties(long? editId, long? pumpId, string? searchTerm, int? pageNumber, CancellationToken cancellationToken)
    {
        ViewData["Title"] = "Party Management";
        var model = await BuildPartyViewModelAsync(editId, pumpId, searchTerm, pageNumber, cancellationToken);
        return View(model);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> SaveParty(PartyManagementViewModel model, string? returnUrl, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null)
        {
            return RedirectToAction("Login", "Account");
        }

        if (model.Form.PumpId <= 0 || string.IsNullOrWhiteSpace(model.Form.PartyName))
        {
            TempData["PartyMessage"] = "Pump and party name are required.";
            if (!string.IsNullOrEmpty(returnUrl))
            {
                return LocalRedirect(returnUrl);
            }
            return RedirectToAction(nameof(Parties), new { pumpId = model.Form.PumpId });
        }

        var request = new ApiSavePartyRequest(
            model.Form.Id,
            model.Form.OwnerId,
            model.Form.PumpId,
            model.Form.PartyName.Trim(),
            model.Form.PartyType,
            model.Form.Address,
            model.Form.Mobile,
            model.Form.Email,
            model.Form.GSTIN,
            model.Form.CreditLimit,
            model.Form.CurrentBalance,
            model.Form.IsActive,
            // Edit me baki ka khaana jaisa khula tha waisa hi hai -> baki ko haath mat lagao.
            // Form khulne aur save hone ke beech koi jama / udhaar aa gayi ho to wo bachi rahe.
            KeepBalance: model.Form.Id > 0 && model.Form.CurrentBalance == model.Form.OriginalBalance);

        var success = await apiClient.SavePartyAsync(token, request, cancellationToken);
        TempData["PartyMessage"] = success.Success ? "Party saved successfully." : (success.ErrorMessage ?? "Unable to save party.");

        if (!string.IsNullOrEmpty(returnUrl))
        {
            return LocalRedirect(returnUrl);
        }
        return RedirectToAction(nameof(Parties), new { pumpId = model.Form.PumpId });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> DeleteParty(long id, long pumpId, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null) return RedirectToAction("Login", "Account");

        var result = await apiClient.DeletePartyAsync(token, id, cancellationToken);
        TempData["PartyMessage"] = result.Success ? "Party deleted successfully." : result.ErrorMessage;
        return RedirectToAction(nameof(Parties), new { pumpId });
    }

    [HttpGet]
    public async Task<IActionResult> TankStock(long? pumpId, long? tankId, CancellationToken cancellationToken)
    {
        ViewData["Title"] = "Tank Stock";
        var model = await BuildTankStockViewModelAsync(pumpId, tankId, cancellationToken);
        return View(model);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> SaveTankStock(TankStockViewModel model, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null)
        {
            return RedirectToAction("Login", "Account");
        }

        if (model.Form.PumpId <= 0 || model.Form.TankId <= 0 || model.Form.Quantity <= 0)
        {
            TempData["TankStockMessage"] = "Pump, tank and quantity are required.";
            return RedirectToAction(nameof(TankStock), new { pumpId = model.Form.PumpId, tankId = model.Form.TankId });
        }

        var request = new ApiSaveTankTransactionRequest(
            model.Form.OwnerId,
            model.Form.PumpId,
            model.Form.TankId,
            model.Form.TxnType,
            model.Form.Quantity,
            model.Form.ReferenceNo,
            model.Form.Notes,
            // Aaj ki tareekh ho to NULL (server ka waqt), warna chuni hui purani tareekh.
            model.Form.TxnDateTime.Date == DateTime.Today ? null : model.Form.TxnDateTime);

        var success = await apiClient.SaveTankTransactionAsync(token, request, cancellationToken);
        TempData["TankStockMessage"] = success.Success ? "Tank stock transaction saved." : (success.ErrorMessage ?? "Unable to save tank stock transaction.");
        return RedirectToAction(nameof(TankStock), new { pumpId = model.Form.PumpId, tankId = model.Form.TankId });
    }

    [HttpGet]
    public async Task<IActionResult> PartyLedger(long? pumpId, long? partyId, string? searchTerm, int? pageNumber, int? pageSize, CancellationToken cancellationToken)
    {
        ViewData["Title"] = "Party Ledger";
        var model = await BuildPartyLedgerViewModelAsync(pumpId, partyId, searchTerm, pageNumber, pageSize, cancellationToken);
        return View(model);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> SavePartyLedger(PartyLedgerViewModel model, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null)
        {
            return RedirectToAction("Login", "Account");
        }

        if (model.Form.PumpId <= 0 || model.Form.PartyId <= 0 || model.Form.Amount <= 0)
        {
            TempData["PartyLedgerMessage"] = "Pump, party and amount are required.";
            return RedirectToAction(nameof(PartyLedger), new { pumpId = model.Form.PumpId, partyId = model.Form.PartyId });
        }

        // Form me pehle se bhari entry (khaate ki line par "Badlein") — nayi nahi banti, wahi
        // sudhrti hai. Wajah zaroori: AuditLog me "pehle kya tha, ab kya, kisne, kyun".
        if (model.Form.Id > 0)
        {
            if (string.IsNullOrWhiteSpace(model.Form.Reason))
            {
                TempData["PartyLedgerMessage"] = "Please write why this entry is being changed.";
                return RedirectToAction(nameof(PartyLedger), new { pumpId = model.Form.PumpId, partyId = model.Form.PartyId });
            }

            var update = new ApiUpdatePartyLedgerEntryRequest(
                model.Form.PumpId,
                model.Form.EntryType,
                model.Form.Amount,
                model.Form.EntryDate,
                model.Form.ReferenceNo,
                model.Form.Notes,
                model.Form.Reason.Trim());

            var updated = await apiClient.UpdatePartyLedgerEntryAsync(token, model.Form.Id, update, cancellationToken);
            TempData["PartyLedgerMessage"] = updated.Success ? "Ledger entry updated." : (updated.ErrorMessage ?? "Could not update the ledger entry.");
            return RedirectToAction(nameof(PartyLedger), new { pumpId = model.Form.PumpId, partyId = model.Form.PartyId });
        }

        var request = new ApiSavePartyLedgerEntryRequest(
            model.Form.OwnerId,
            model.Form.PumpId,
            model.Form.PartyId,
            model.Form.EntryType,
            model.Form.Amount,
            model.Form.EntryDate,
            model.Form.ReferenceNo,
            model.Form.Notes);

        var success = await apiClient.SavePartyLedgerAsync(token, request, cancellationToken);
        TempData["PartyLedgerMessage"] = success.Success ? "Party ledger entry saved." : (success.ErrorMessage ?? "Unable to save party ledger entry.");
        return RedirectToAction(nameof(PartyLedger), new { pumpId = model.Form.PumpId, partyId = model.Form.PartyId });
    }

    /// <summary>
    /// Khaate ki haath se bani galat entry hatana (do baar chadh gayi, galat party par chadh gayi).
    /// Din ke collection / bill wali line API mana kar deti hai — wo wahin se badalti hai.
    /// </summary>
    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> DeletePartyLedger(long id, long pumpId, long partyId, string? reason, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null) return RedirectToAction("Login", "Account");

        if (string.IsNullOrWhiteSpace(reason))
        {
            TempData["PartyLedgerMessage"] = "Please write why this entry is being deleted.";
            return RedirectToAction(nameof(PartyLedger), new { pumpId, partyId });
        }

        var result = await apiClient.DeletePartyLedgerEntryAsync(token, id, pumpId, reason.Trim(), cancellationToken);
        TempData["PartyLedgerMessage"] = result.Success ? "Ledger entry deleted." : (result.ErrorMessage ?? "Could not delete the ledger entry.");
        return RedirectToAction(nameof(PartyLedger), new { pumpId, partyId });
    }

    [HttpGet]
    public async Task<IActionResult> Purchase(long? pumpId, DateTime? fromDate, DateTime? toDate, string? searchTerm, int? pageNumber, long? editId, CancellationToken cancellationToken)
    {
        ViewData["Title"] = "Purchase Management";
        var pNum = pageNumber ?? 1;
        var model = await BuildPurchaseViewModelAsync(pumpId, fromDate, toDate, searchTerm, pNum, ListPageSize, editId, cancellationToken);
        return View(model);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> SavePurchase(PurchaseManagementViewModel model, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null)
        {
            return RedirectToAction("Login", "Account");
        }

        // Bill ki rakam hi sach hai (Section AE): matra aur rakam, dono chahiye.
        var items = model.Form.Items
            .Where(x => x.ProductId > 0 && x.Quantity > 0 && x.Amount > 0)
            .ToList();

        if (model.Form.PumpId <= 0 || model.Form.VendorId <= 0 || string.IsNullOrWhiteSpace(model.Form.InvoiceNo) || items.Count == 0)
        {
            TempData["PurchaseMessage"] = "Pump, vendor, invoice and at least one line with quantity and bill amount are required.";
            return RedirectToAction(nameof(Purchase), new { pumpId = model.Form.PumpId });
        }

        var request = new ApiSavePurchaseRequest(
            model.Form.Id == 0 ? null : model.Form.Id,
            model.Form.OwnerId,
            model.Form.PumpId,
            model.Form.VendorId,
            model.Form.InvoiceNo.Trim(),
            model.Form.InvoiceDate,
            model.Form.VehicleNo,
            model.Form.DriverName,
            model.Form.Notes,
            // Rate rakam se nikla hua (4 ank) - purani API isi se chalti hai; nayi API
            // Amount ko hi sach maanti hai.
            items.Select(x => new ApiPurchaseItemRequest(
                x.ProductId, x.TankId, x.Quantity,
                decimal.Round(x.Amount / x.Quantity, 4, MidpointRounding.AwayFromZero),
                decimal.Round(x.Amount, 2, MidpointRounding.AwayFromZero))).ToList());

        var id = await apiClient.SavePurchaseAsync(token, request, cancellationToken);
        TempData["PurchaseMessage"] = id is null ? "Unable to save purchase." : (model.Form.Id > 0 ? "Purchase updated successfully." : $"Purchase saved (Id: {id}).");
        return RedirectToAction(nameof(Purchase), new { pumpId = model.Form.PumpId });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> DeleteVendor(long id, long pumpId, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null) return RedirectToAction("Login", "Account");

        var result = await apiClient.DeleteVendorAsync(token, id, cancellationToken);
        TempData["VendorMessage"] = result.Success ? "Vendor deleted successfully." : result.ErrorMessage;
        return RedirectToAction(nameof(Vendors), new { pumpId = pumpId });
    }

    [HttpGet]
    public async Task<IActionResult> Vendors(long? pumpId, long? editId, CancellationToken cancellationToken)
    {
        ViewData["Title"] = "Vendor Management";
        var model = await BuildVendorViewModelAsync(pumpId, editId, cancellationToken);
        return View(model);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> SaveVendor(VendorManagementViewModel model, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null)
        {
            return RedirectToAction("Login", "Account");
        }

        if (model.Form.PumpId <= 0 || string.IsNullOrWhiteSpace(model.Form.VendorName))
        {
            TempData["VendorMessage"] = "Pump and vendor name are required.";
            return RedirectToAction(nameof(Vendors), new { pumpId = model.Form.PumpId });
        }

        var request = new ApiSaveVendorRequest(
            model.Form.Id == 0 ? null : model.Form.Id,
            model.Form.OwnerId,
            model.Form.PumpId,
            model.Form.VendorName.Trim(),
            model.Form.ContactNo?.Trim(),
            model.Form.GSTIN?.Trim(),
            model.Form.Address?.Trim(),
            model.Form.IsActive);

        var success = await apiClient.SaveVendorAsync(token, request, cancellationToken);
        TempData["VendorMessage"] = success.Success ? "Vendor saved successfully." : (success.ErrorMessage ?? "Unable to save vendor.");
        return RedirectToAction(nameof(Vendors), new { pumpId = model.Form.PumpId });
    }

    [HttpGet]
    public async Task<IActionResult> StockReconcile(long? pumpId, long? tankId, DateTime? fromDate, DateTime? toDate, string? searchTerm, int? pageNumber, CancellationToken cancellationToken)
    {
        ViewData["Title"] = "Stock Reconciliation";
        var pNum = pageNumber ?? 1;
        var model = await BuildStockReconciliationViewModelAsync(pumpId, tankId, fromDate, toDate, searchTerm, pNum, ListPageSize, cancellationToken);
        return View(model);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> SaveStockReconcile(StockReconciliationViewModel model, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null)
        {
            return RedirectToAction("Login", "Account");
        }

        if (model.Form.PumpId <= 0 || model.Form.TankId <= 0)
        {
            TempData["StockReconcileMessage"] = "Pump and tank are required.";
            return RedirectToAction(nameof(StockReconcile), new { pumpId = model.Form.PumpId });
        }

        var request = new ApiSaveStockReconciliationRequest(
            model.Form.OwnerId,
            model.Form.PumpId,
            model.Form.TankId,
            model.Form.ReconciliationDate,
            model.Form.BookStock,
            model.Form.PhysicalStock,
            model.Form.Reason);

        var success = await apiClient.SaveStockReconciliationAsync(token, request, cancellationToken);
        TempData["StockReconcileMessage"] = success.Success ? "Stock reconciliation saved." : (success.ErrorMessage ?? "Unable to save stock reconciliation.");
        return RedirectToAction(nameof(StockReconcile), new { pumpId = model.Form.PumpId, tankId = model.Form.TankId });
    }

    [HttpGet]
    public async Task<IActionResult> Cashbook(long? pumpId, DateTime? fromDate, DateTime? toDate, string? searchTerm, int? pageNumber, CancellationToken cancellationToken)
    {
        ViewData["Title"] = "Cashbook";
        var pNum = pageNumber ?? 1;
        var model = await BuildCashbookViewModelAsync(pumpId, fromDate, toDate, searchTerm, pNum, ListPageSize, cancellationToken);
        return View(model);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> SaveCashbook(CashbookViewModel model, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null)
        {
            return RedirectToAction("Login", "Account");
        }

        if (model.Form.PumpId <= 0 || model.Form.Amount <= 0)
        {
            TempData["CashbookMessage"] = "Pump and amount are required.";
            return RedirectToAction(nameof(Cashbook), new { pumpId = model.Form.PumpId });
        }

        var request = new ApiSaveCashTransactionRequest(
            model.Form.OwnerId,
            model.Form.PumpId,
            model.Form.ShiftId,
            model.Form.TxnType,
            model.Form.Amount,
            model.Form.ReferenceNo,
            model.Form.Narration,
            model.Form.TxnDate);

        var success = await apiClient.SaveCashTransactionAsync(token, request, cancellationToken);
        TempData["CashbookMessage"] = success.Success ? "Cash transaction saved." : (success.ErrorMessage ?? "Unable to save cash transaction.");
        return RedirectToAction(nameof(Cashbook), new { pumpId = model.Form.PumpId });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> DeleteCashTransaction(long id, long pumpId, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null) return RedirectToAction("Login", "Account");

        var result = await apiClient.DeleteCashTransactionAsync(token, id, cancellationToken);
        TempData["CashbookMessage"] = result.Success ? "Cash transaction deleted." : result.ErrorMessage;
        return RedirectToAction(nameof(Cashbook), new { pumpId });
    }


    [HttpGet]
    public async Task<IActionResult> Expenses(long? pumpId, DateTime? fromDate, DateTime? toDate, string? searchTerm, int? pageNumber, CancellationToken cancellationToken)
    {
        ViewData["Title"] = "Expense Management";
        var pNum = pageNumber ?? 1;
        var model = await BuildExpenseViewModelAsync(pumpId, fromDate, toDate, searchTerm, pNum, ListPageSize, cancellationToken);
        return View(model);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> SaveExpense(ExpenseViewModel model, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null)
        {
            return RedirectToAction("Login", "Account");
        }

        if (model.Form.PumpId <= 0 || model.Form.ExpenseHeadId <= 0 || model.Form.Amount <= 0)
        {
            TempData["ExpenseMessage"] = "Pump, expense head and amount are required.";
            return RedirectToAction(nameof(Expenses), new { pumpId = model.Form.PumpId });
        }

        if (!IsOneOf(model.Form.PaymentMode, CashPaymentModes))
        {
            TempData["ExpenseMessage"] = "Please pick the payment mode from the list.";
            return RedirectToAction(nameof(Expenses), new { pumpId = model.Form.PumpId });
        }

        var request = new ApiSaveExpenseRequest(
            model.Form.OwnerId,
            model.Form.PumpId,
            model.Form.ShiftId,
            model.Form.ExpenseHeadId,
            model.Form.Amount,
            model.Form.PaymentMode,
            model.Form.ReferenceNo,
            model.Form.Narration,
            model.Form.ExpenseDate);

        var success = await apiClient.SaveExpenseAsync(token, request, cancellationToken);
        TempData["ExpenseMessage"] = success.Success ? "Expense entry saved." : (success.ErrorMessage ?? "Unable to save expense.");
        return RedirectToAction(nameof(Expenses), new { pumpId = model.Form.PumpId });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> DeleteExpenseHead(long id, long pumpId, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null) return RedirectToAction("Login", "Account");

        var result = await apiClient.DeleteExpenseHeadAsync(token, id, cancellationToken);
        TempData["ExpenseMessage"] = result.Success ? "Expense head deleted successfully." : result.ErrorMessage;
        return RedirectToAction(nameof(Expenses), new { pumpId = pumpId });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> DeleteExpense(long id, long pumpId, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null) return RedirectToAction("Login", "Account");

        var result = await apiClient.DeleteExpenseAsync(token, id, cancellationToken);
        TempData["ExpenseMessage"] = result.Success ? "Expense deleted successfully." : (result.ErrorMessage ?? "Unable to delete expense.");
        return RedirectToAction(nameof(Expenses), new { pumpId });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> DeletePurchase(long id, long pumpId, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null) return RedirectToAction("Login", "Account");

        var result = await apiClient.DeletePurchaseAsync(token, id, cancellationToken);
        TempData["PurchaseMessage"] = result.Success ? "Purchase deleted successfully." : (result.ErrorMessage ?? "Unable to delete purchase.");
        return RedirectToAction(nameof(Purchase), new { pumpId });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> VoidSale(long id, long pumpId, string? reason, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null) return RedirectToAction("Login", "Account");

        var result = await apiClient.VoidSaleAsync(token, id, reason, cancellationToken);
        TempData["SalesMessage"] = result.Success ? "Sale voided successfully." : (result.ErrorMessage ?? "Unable to void sale.");
        return RedirectToAction(nameof(Sales), new { pumpId });
    }

    [HttpGet]
    public async Task<IActionResult> DipTesting(long? pumpId, DateTime? fromDate, DateTime? toDate, int? pageNumber, int? pageSize, CancellationToken cancellationToken)
    {
        ViewData["Title"] = "Dip & Testing";
        var pNum = pageNumber ?? 1;

        // Page size 50 tha, isliye pager kabhi dikhta hi nahi tha aur table
        // lambi hoti chali jaati thi. Dip roz ki cheez hai — 10 ek stack me
        // aaram se dikh jaate hain, purane pager se mil jaate hain.
        var pSize = pageSize is >= 5 and <= 200 ? pageSize.Value : 10;

        var model = await BuildDipTestingViewModelAsync(pumpId, fromDate, toDate, pNum, pSize, cancellationToken);
        return View(model);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> SaveDipReading(DipTestingViewModel model, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null)
        {
            return RedirectToAction("Login", "Account");
        }

        if (model.DipReadingForm.PumpId <= 0 || model.DipReadingForm.TankId <= 0 || model.DipReadingForm.DipCm <= 0)
        {
            TempData["DipTestingMessage"] = "Pump, tank and dip cm are required.";
            return RedirectToAction(nameof(DipTesting), new { pumpId = model.DipReadingForm.PumpId });
        }

        var request = new ApiSaveDipReadingRequest(
            model.DipReadingForm.OwnerId,
            model.DipReadingForm.PumpId,
            model.DipReadingForm.TankId,
            model.DipReadingForm.ReadingDate,
            model.DipReadingForm.ShiftId,
            model.DipReadingForm.DipCm,
            model.DipReadingForm.WaterDipCm,
            model.DipReadingForm.Density,
            model.DipReadingForm.Temperature,
            model.DipReadingForm.ExpectedStock,
            model.DipReadingForm.ActualStock);

        var result = await apiClient.SaveDipReadingAsync(token, request, cancellationToken);
        TempData["DipTestingMessage"] = result.Success ? "Dip reading saved." : result.ErrorMessage;
        return RedirectToAction(nameof(DipTesting), new { pumpId = model.DipReadingForm.PumpId });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> SaveTestingLoss(DipTestingViewModel model, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null)
        {
            return RedirectToAction("Login", "Account");
        }

        if (model.TestingLossForm.PumpId <= 0 || model.TestingLossForm.TankId <= 0 || model.TestingLossForm.Quantity <= 0)
        {
            TempData["DipTestingMessage"] = "Pump, tank and quantity are required.";
            return RedirectToAction(nameof(DipTesting), new { pumpId = model.TestingLossForm.PumpId });
        }

        var request = new ApiSaveTestingLossRequest(
            model.TestingLossForm.OwnerId,
            model.TestingLossForm.PumpId,
            model.TestingLossForm.TankId,
            model.TestingLossForm.LossDate,
            model.TestingLossForm.ShiftId,
            model.TestingLossForm.LossType,
            model.TestingLossForm.Quantity,
            model.TestingLossForm.Notes);

        var result = await apiClient.SaveTestingLossAsync(token, request, cancellationToken);
        TempData["DipTestingMessage"] = result.Success ? "Testing loss saved." : result.ErrorMessage;
        return RedirectToAction(nameof(DipTesting), new { pumpId = model.TestingLossForm.PumpId });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> EditDipReading(long id, DipTestingViewModel model, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null) return RedirectToAction("Login", "Account");

        var request = new ApiUpdateDipReadingRequest(
            model.DipReadingForm.OwnerId,
            model.DipReadingForm.PumpId,
            model.DipReadingForm.TankId,
            model.DipReadingForm.ReadingDate,
            model.DipReadingForm.ShiftId,
            model.DipReadingForm.DipCm,
            model.DipReadingForm.WaterDipCm,
            model.DipReadingForm.Density,
            model.DipReadingForm.Temperature,
            model.DipReadingForm.ExpectedStock,
            model.DipReadingForm.ActualStock);

        var result = await apiClient.UpdateDipReadingAsync(token, id, request, cancellationToken);
        TempData["DipTestingMessage"] = result.Success ? "Dip reading updated." : result.ErrorMessage;
        return RedirectToAction(nameof(DipTesting), new { pumpId = model.DipReadingForm.PumpId });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> EditTestingLoss(long id, DipTestingViewModel model, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null) return RedirectToAction("Login", "Account");

        var request = new ApiUpdateTestingLossRequest(
            model.TestingLossForm.OwnerId,
            model.TestingLossForm.PumpId,
            model.TestingLossForm.TankId,
            model.TestingLossForm.LossDate,
            model.TestingLossForm.ShiftId,
            model.TestingLossForm.LossType,
            model.TestingLossForm.Quantity,
            model.TestingLossForm.Notes);

        var result = await apiClient.UpdateTestingLossAsync(token, id, request, cancellationToken);
        TempData["DipTestingMessage"] = result.Success ? "Testing loss updated." : result.ErrorMessage;
        return RedirectToAction(nameof(DipTesting), new { pumpId = model.TestingLossForm.PumpId });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> ToggleDipActive(long id, long ownerId, long pumpId, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null) return RedirectToAction("Login", "Account");

        var result = await apiClient.ToggleDipReadingActiveAsync(token, id, ownerId, pumpId, cancellationToken);
        TempData["DipTestingMessage"] = result.Success ? "Dip reading status toggled." : result.ErrorMessage;
        return RedirectToAction(nameof(DipTesting), new { pumpId });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> ToggleLossActive(long id, long ownerId, long pumpId, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null) return RedirectToAction("Login", "Account");

        var result = await apiClient.ToggleTestingLossActiveAsync(token, id, ownerId, pumpId, cancellationToken);
        TempData["DipTestingMessage"] = result.Success ? "Testing loss status toggled." : result.ErrorMessage;
        return RedirectToAction(nameof(DipTesting), new { pumpId });
    }

    [HttpGet]
    public async Task<IActionResult> DayBook(long? pumpId, DateOnly? dateFrom, DateOnly? dateTo, CancellationToken cancellationToken)
    {
        ViewData["Title"] = "Day Book Report";
        var model = await BuildDayBookViewModelAsync(pumpId, dateFrom, dateTo, cancellationToken);
        return View(model);
    }

    [HttpGet]
    public async Task<IActionResult> ExportDayBookCsv(long pumpId, DateOnly? dateFrom, DateOnly? dateTo, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null) return Unauthorized();

        var ownerId = GetOwnerId();
        var from = dateFrom ?? DateOnly.FromDateTime(DateTime.Today.AddDays(-7));
        var to = dateTo ?? DateOnly.FromDateTime(DateTime.Today);

        var entries = await apiClient.GetDayBookAsync(token, ownerId, pumpId, from, to, cancellationToken);
        
        var builder = new System.Text.StringBuilder();
        builder.AppendLine("Date,Type,Ref No,Description,Debit,Credit");
        foreach (var entry in entries)
        {
            var date = entry.EntryDateTime.ToString("dd-MM-yyyy HH:mm");
            var desc = entry.Description?.Replace("\"", "\"\"") ?? "";
            builder.AppendLine($"{date},{entry.EntryType},{entry.ReferenceNo},\"{desc}\",{entry.Debit:0.00},{entry.Credit:0.00}");
        }

        var fileName = $"DayBook_{pumpId}_{from:yyyyMMdd}_to_{to:yyyyMMdd}.csv";
        return File(System.Text.Encoding.UTF8.GetBytes(builder.ToString()), "text/csv", fileName);
    }

    /// <summary>
    /// CSV me comma, quote ya nayi line hone par file toot jaati hai. Ye teeno
    /// sambhal leta hai - CA ko file dete waqt yahi sabse zyada dikkat karta hai
    /// (party ke naam me comma aam baat hai: "Sharma Traders, Barabanki").
    /// </summary>
    private static string Csv(string? value)
    {
        if (string.IsNullOrEmpty(value))
        {
            return string.Empty;
        }

        if (value.Contains(',') || value.Contains('"') || value.Contains('\n') || value.Contains('\r'))
        {
            return "\"" + value.Replace("\"", "\"\"") + "\"";
        }

        return value;
    }

    private FileResult CsvFile(System.Text.StringBuilder builder, string fileName)
    {
        // BOM ke bina Excel me Hindi/rupee ka nishaan tuta hua dikhta hai.
        var bytes = new System.Text.UTF8Encoding(true).GetBytes(builder.ToString());
        return File(bytes, "text/csv", fileName);
    }

    [HttpGet]
    public async Task<IActionResult> ExportDailyStockRegisterCsv(long pumpId, long productId, int month, int year, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null) return Unauthorized();

        var rows = await apiClient.GetDailyStockRegisterAsync(token, pumpId, productId, month, year, cancellationToken);

        var b = new System.Text.StringBuilder();
        // CA ko yahi file jaati hai, isliye jo screen par dikhta hai wo poora
        // yahan bhi aana chahiye - khaas kar Book vs Physical closing aur rate.
        b.AppendLine("Date,Opening Stock,Receipt,Total Stock,Sales by Meter,Pump Test,Net Sales by Meter,Cumulative Sales,Sales by Dip,Book Closing,Physical Closing (Dip),Stock Checked,Register Closing,Variation (L),Variation Value,Variation Cumulative,Rate,Sale Amount,Cumulative Sale Amount,Remarks");
        foreach (var r in rows)
        {
            b.AppendLine(string.Join(",",
                r.Date.ToString("dd-MM-yyyy"),
                r.OpeningStock.ToString("0.##"), r.Receipt.ToString("0.##"),
                r.TotalStock.ToString("0.##"), r.SalesByMeter.ToString("0.##"),
                r.PumpTest.ToString("0.##"), r.NetSalesByMeter.ToString("0.##"),
                r.CumulativeSales.ToString("0.##"), r.SalesByDip.ToString("0.##"),
                r.BookClosingStock.ToString("0.##"),
                // Napa nahi gaya to khaali - 0 likhna galat hota.
                r.StockChecked && r.PhysicalClosingStock.HasValue
                    ? r.PhysicalClosingStock.Value.ToString("0.##") : "",
                r.StockChecked ? "Yes" : "No",
                r.ClosingStock.ToString("0.##"), r.VariationDaily.ToString("0.##"),
                r.VariationValue.ToString("0.00"), r.VariationCumulative.ToString("0.##"),
                r.RateApplied.ToString("0.000"), r.SalesValue.ToString("0.00"),
                r.CumulativeSalesValue.ToString("0.00"),
                Csv(r.Remarks)));
        }

        // Total ki line screen par to thi par file me chhoot gayi thi - CA ko
        // file hi jaati hai, aur wahan mahine ka jod khud lagana padta tha.
        // Jo screen ke footer me hai, bilkul wahi yahan bhi:
        //   - Receipt / Sale / Test / Variation ka JOD
        //   - Book aur Register closing ka jod NAHI - mahine ke AAKHIRI din ka
        //     closing (stock jodne ki cheez nahi hoti)
        if (rows.Count > 0)
        {
            var last = rows[rows.Count - 1];
            var daysChecked = rows.Count(x => x.StockChecked);

            b.AppendLine();
            b.AppendLine(string.Join(",",
                "TOTAL",
                "",                                                   // Opening
                rows.Sum(x => x.Receipt).ToString("0.##"),
                "",                                                   // Total Stock
                rows.Sum(x => x.SalesByMeter).ToString("0.##"),
                rows.Sum(x => x.PumpTest).ToString("0.##"),
                rows.Sum(x => x.NetSalesByMeter).ToString("0.##"),
                "",                                                   // Cumulative Sales
                rows.Sum(x => x.SalesByDip).ToString("0.##"),
                last.BookClosingStock.ToString("0.##"),               // aakhri din ka
                "",                                                   // Physical Closing
                Csv($"{daysChecked} of {rows.Count} days dip taken"),
                last.ClosingStock.ToString("0.##"),                   // aakhri din ka
                rows.Sum(x => x.VariationDaily).ToString("0.##"),
                rows.Sum(x => x.VariationValue).ToString("0.00"),
                "",                                                   // Variation Cumulative
                "",                                                   // Rate
                rows.Sum(x => x.SalesValue).ToString("0.00"),
                "",                                                   // Cumulative Sale Amount
                ""));                                                 // Remarks
        }

        return CsvFile(b, $"DailyStockRegister_{pumpId}_{productId}_{year}-{month:00}.csv");
    }

    [HttpGet]
    public async Task<IActionResult> ExportOutstandingCsv(long pumpId, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null) return Unauthorized();

        var rows = await apiClient.GetOutstandingAsync(token, GetOwnerId(), pumpId, cancellationToken);

        var b = new System.Text.StringBuilder();
        b.AppendLine("Party,Type,Credit Limit,Outstanding,Last Sale Date");
        foreach (var r in rows)
        {
            b.AppendLine(string.Join(",",
                Csv(r.PartyName), Csv(r.PartyType),
                r.CreditLimit.ToString("0.00"), r.CurrentBalance.ToString("0.00"),
                r.LastSaleDate?.ToString("dd-MM-yyyy") ?? ""));
        }

        b.AppendLine();
        b.AppendLine($"Total,,,{rows.Sum(x => x.CurrentBalance):0.00},");

        return CsvFile(b, $"Outstanding_{pumpId}_{DateTime.Today:yyyyMMdd}.csv");
    }

    [HttpGet]
    public async Task<IActionResult> ExportTankStockCsv(long pumpId, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null) return Unauthorized();

        var tanks = await apiClient.GetTanksAsync(token, GetOwnerId(), pumpId, null, 1, 1000, cancellationToken);

        var b = new System.Text.StringBuilder();
        b.AppendLine("Tank,Product,Unit,Capacity,Safe Fill Level,Current Stock,Status");
        foreach (var t in tanks.Items)
        {
            var status = t.CurrentStock <= t.SafeFillLevel ? "REFILL NEEDED" : "OK";
            b.AppendLine(string.Join(",",
                Csv(t.Name), Csv(t.ProductName), Csv(t.Unit),
                t.Capacity.ToString("0.##"), t.SafeFillLevel.ToString("0.##"),
                t.CurrentStock.ToString("0.##"), status));
        }

        return CsvFile(b, $"TankStock_{pumpId}_{DateTime.Today:yyyyMMdd}.csv");
    }

    [HttpGet]
    public async Task<IActionResult> ExportSalesRegisterCsv(long pumpId, DateTime? fromDate, DateTime? toDate, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null) return Unauthorized();

        // Poora register chahiye, isliye badi page size. CA ko mahine bhar ki
        // file chahiye hoti hai, 50-50 ke tukdon me nahi.
        var sales = await apiClient.GetSalesAsync(token, GetOwnerId(), pumpId,
            fromDate, toDate, null, 1, 10000, cancellationToken);

        var b = new System.Text.StringBuilder();
        b.AppendLine("Bill No,Date,Customer,Vehicle,Payment Mode,Attendant,Amount,Status,Void Reason");
        foreach (var x in sales.Items)
        {
            b.AppendLine(string.Join(",",
                Csv(x.BillNo), x.BillDateTime.ToString("dd-MM-yyyy HH:mm"),
                Csv(x.CustomerName), Csv(x.VehicleNo), Csv(x.PaymentMode),
                Csv(x.AttendantName), x.TotalAmount.ToString("0.00"),
                x.IsVoid ? "VOID" : "ACTIVE", Csv(x.VoidReason)));
        }

        // Void wale bill file me dikhte hain (taaki record poora rahe) lekin
        // total me nahi ginte - wahi hisaab jo report me hai.
        b.AppendLine();
        b.AppendLine($"Total (void chhod kar),,,,,,{sales.Items.Where(x => !x.IsVoid).Sum(x => x.TotalAmount):0.00},,");

        var from = fromDate?.ToString("yyyyMMdd") ?? "all";
        var to = toDate?.ToString("yyyyMMdd") ?? "all";
        return CsvFile(b, $"SalesRegister_{pumpId}_{from}_to_{to}.csv");
    }

    /// <summary>
    /// Nozzle-wise aadmi ka cash. Pump par har nozzle par alag aadmi hota hai —
    /// shift shuru me chhutta diya jaata hai, baad me usse cash liya jaata hai.
    /// Cash lena shift band karne se ALAG hai: poore din ka cash raat me ek saath
    /// bhi liya ja sakta hai, isliye "baaki" ki list alag dikhti hai.
    /// </summary>
    [HttpGet]
    public async Task<IActionResult> NozzleCash(long? pumpId, long? shiftId, CancellationToken cancellationToken)
    {
        ViewData["Title"] = "Nozzle Cash";
        var model = await BuildNozzleCashViewModelAsync(pumpId, shiftId, cancellationToken);
        return View(model);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> SaveNozzleAttendant(long shiftId, long nozzleId, long? employeeId, decimal? floatGiven, long pumpId, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null) return RedirectToAction("Login", "Account");

        // employeeId 0 ka matlab "koi nahi chuna" — NULL bhejna hai.
        var (ok, error) = await apiClient.SetNozzleAttendantAsync(
            token, shiftId, nozzleId, employeeId is > 0 ? employeeId : null, floatGiven, cancellationToken);

        TempData["NozzleCashMessage"] = ok ? "Saved." : (error ?? "Could not save.");
        if (!ok) { TempData["NozzleCashError"] = true; }

        return RedirectToAction(nameof(NozzleCash), new { pumpId, shiftId });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> CollectNozzleCash(long shiftId, long nozzleId, decimal cashReturned, decimal? slipsAmount, string? notes, long pumpId, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null) return RedirectToAction("Login", "Account");

        var (ok, error) = await apiClient.CollectNozzleCashAsync(
            token, shiftId, nozzleId, cashReturned, slipsAmount, notes, cancellationToken);

        TempData["NozzleCashMessage"] = ok ? "Cash collected." : (error ?? "Could not record the cash.");
        if (!ok) { TempData["NozzleCashError"] = true; }

        return RedirectToAction(nameof(NozzleCash), new { pumpId, shiftId });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> UndoNozzleCash(long shiftId, long nozzleId, long pumpId, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null) return RedirectToAction("Login", "Account");

        var ok = await apiClient.UndoNozzleCashAsync(token, shiftId, nozzleId, cancellationToken);
        TempData["NozzleCashMessage"] = ok.Success ? "Entry removed." : (ok.ErrorMessage ?? "Could not remove the entry.");
        if (!ok.Success) { TempData["NozzleCashError"] = true; }

        return RedirectToAction(nameof(NozzleCash), new { pumpId, shiftId });
    }

    [HttpGet]
    public async Task<IActionResult> AttendantCash(long? pumpId, DateOnly? fromDate, DateOnly? toDate, CancellationToken cancellationToken)
    {
        ViewData["Title"] = "Attendant Cash Report";

        var token = GetToken();
        if (token is null) return RedirectToAction("Login", "Account");

        var ownerId = GetOwnerId();
        var pumps = await apiClient.GetPumpsAsync(token, ownerId, cancellationToken);
        var selectedPumpId = pumpId ?? pumps.FirstOrDefault()?.Id ?? 0;

        var from = fromDate ?? DateOnly.FromDateTime(new DateTime(DateTime.Today.Year, DateTime.Today.Month, 1));
        var to = toDate ?? DateOnly.FromDateTime(DateTime.Today);

        var rows = await apiClient.GetAttendantCashReportAsync(token, selectedPumpId, from, to, cancellationToken);

        return View(new AttendantCashReportViewModel
        {
            PumpId = selectedPumpId,
            Pumps = pumps,
            FromDate = from,
            ToDate = to,
            Rows = rows
        });
    }

    [HttpGet]
    public async Task<IActionResult> ExportAttendantCashCsv(long pumpId, DateOnly fromDate, DateOnly toDate, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null) return Unauthorized();

        var rows = await apiClient.GetAttendantCashReportAsync(token, pumpId, fromDate, toDate, cancellationToken);

        var b = new System.Text.StringBuilder();
        b.AppendLine("Attendant,Shifts,Meter Sale,Float Given,Slips,Expected Cash,Cash Returned,Short/Excess,Pending Count,Pending Amount");
        foreach (var r in rows)
        {
            b.AppendLine(string.Join(",",
                Csv(r.EmployeeName), r.Shifts,
                r.TotalMeterSale.ToString("0.00"), r.TotalFloat.ToString("0.00"),
                r.TotalSlips.ToString("0.00"), r.TotalExpected.ToString("0.00"),
                r.TotalReturned.ToString("0.00"), r.TotalShortExcess.ToString("0.00"),
                r.PendingCount, r.PendingAmount.ToString("0.00")));
        }

        return CsvFile(b, $"AttendantCash_{pumpId}_{fromDate:yyyyMMdd}_to_{toDate:yyyyMMdd}.csv");
    }

    /// <summary>
    /// User manual — Hindi aur English dono, ek hi page par (upar se badalta hai).
    /// LOGIN KE ANDAR rakha hai, public login page par nahi: grahak ko madad milti
    /// rahe, lekin poori feature list internet par khuli na pade.
    /// Print/PDF ke liye alag CSS hai, to user "Save as PDF" karke rakh sakta hai.
    /// </summary>
    [HttpGet]
    public IActionResult Manual()
    {
        ViewData["Title"] = "User Manual";
        return View();
    }

    [HttpGet]
    public async Task<IActionResult> Reports(CancellationToken cancellationToken)
    {
        ViewData["Title"] = "Reports";
        var model = await BuildReportsHomeViewModelAsync(cancellationToken);
        return View(model);
    }

    [HttpGet]
    public async Task<IActionResult> Outstanding(long? pumpId, CancellationToken cancellationToken)
    {
        ViewData["Title"] = "Outstanding Report";
        var model = await BuildOutstandingReportViewModelAsync(pumpId, cancellationToken);
        return View(model);
    }

    [HttpGet]
    public async Task<IActionResult> PumpComparison(DateOnly? dateFrom, DateOnly? dateTo, CancellationToken cancellationToken)
    {
        ViewData["Title"] = "Pump Comparison Report";
        var model = await BuildPumpComparisonReportViewModelAsync(dateFrom, dateTo, cancellationToken);
        return View(model);
    }

    [HttpGet]
    public async Task<IActionResult> DailyStockRegister(long? pumpId, long? productId, int? month, int? year, CancellationToken cancellationToken)
    {
        ViewData["Title"] = "Daily Stock Register";
        var model = await BuildDailyStockRegisterViewModelAsync(pumpId, productId, month, year, cancellationToken);
        return View(model);
    }

    /// <summary>Maahwar bikri-khareed register (Section AD).</summary>
    [HttpGet]
    public async Task<IActionResult> SalePurchaseRegister(long? pumpId, long? productId, int? month, int? year, CancellationToken cancellationToken)
    {
        ViewData["Title"] = "Sale / Purchase Register";
        var model = await BuildSalePurchaseRegisterViewModelAsync(pumpId, productId, month, year, cancellationToken);
        return View(model);
    }

    [HttpGet]
    public async Task<IActionResult> ExportSalePurchaseRegisterCsv(long pumpId, long productId, int month, int year, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null) return Unauthorized();

        var rows = await apiClient.GetSalePurchaseRegisterAsync(token, pumpId, productId, month, year, cancellationToken);

        var b = new System.Text.StringBuilder();
        b.AppendLine("Date,Sale (L),Rate,Sale Amount,Purchase (L),Purchase Amount");
        foreach (var r in rows)
        {
            b.AppendLine(string.Join(",",
                r.Date.ToString("dd-MM-yyyy"),
                r.SaleQty.ToString("0.##"),
                r.Rate.ToString("0.###"),
                r.SaleAmount.ToString("0.00"),
                r.PurchaseQty.ToString("0.##"),
                r.PurchaseAmount.ToString("0.00")));
        }

        // Rajistar ki tarah neeche mahine ka jod. Rate ka jod nahi hota - wo har din ka apna hai.
        if (rows.Count > 0)
        {
            b.AppendLine();
            b.AppendLine(string.Join(",",
                "TOTAL",
                rows.Sum(x => x.SaleQty).ToString("0.##"),
                "",
                rows.Sum(x => x.SaleAmount).ToString("0.00"),
                rows.Sum(x => x.PurchaseQty).ToString("0.##"),
                rows.Sum(x => x.PurchaseAmount).ToString("0.00")));
        }

        return CsvFile(b, $"SalePurchaseRegister_{pumpId}_{productId}_{year}-{month:00}.csv");
    }

    [HttpGet]
    public async Task<IActionResult> FleetContracts(long? pumpId, CancellationToken cancellationToken)
    {
        ViewData["Title"] = "Fleet Contracts";
        var model = await BuildFleetContractsViewModelAsync(pumpId, cancellationToken);
        return View(model);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> SaveFleetContract(FleetContractsViewModel model, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null)
        {
            return RedirectToAction("Login", "Account");
        }

        if (model.Form.PumpId <= 0 || model.Form.PartyId <= 0 || model.Form.ProductId <= 0 || model.Form.ContractRate <= 0)
        {
            TempData["FleetContractMessage"] = "Pump, party, product and contract rate are required.";
            return RedirectToAction(nameof(FleetContracts), new { pumpId = model.Form.PumpId });
        }

        var request = new ApiSaveFleetContractRequest(
            model.Form.Id,
            model.Form.OwnerId,
            model.Form.PumpId,
            model.Form.PartyId,
            model.Form.ProductId,
            model.Form.ContractRate,
            model.Form.ValidFrom,
            model.Form.ValidTo,
            model.Form.IsActive,
            model.Form.Notes);

        var result = await apiClient.SaveFleetContractAsync(token, request, cancellationToken);
        TempData["FleetContractMessage"] = result.Success ? "Fleet contract saved." : result.ErrorMessage ?? "Unable to save fleet contract.";
        return RedirectToAction(nameof(FleetContracts), new { pumpId = model.Form.PumpId });
    }

    [HttpGet]
    public async Task<IActionResult> CouponBooks(long? pumpId, long? couponBookId, CancellationToken cancellationToken)
    {
        ViewData["Title"] = "Coupon Books";
        var model = await BuildCouponBooksViewModelAsync(pumpId, couponBookId, cancellationToken);
        return View(model);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> SaveCouponBook(CouponBooksViewModel model, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null)
        {
            return RedirectToAction("Login", "Account");
        }

        if (model.Form.PumpId <= 0 || string.IsNullOrWhiteSpace(model.Form.BookCode) || model.Form.Denomination <= 0 || model.Form.TotalCoupons <= 0)
        {
            TempData["CouponBookMessage"] = "Pump, book code, denomination and total coupons are required.";
            return RedirectToAction(nameof(CouponBooks), new { pumpId = model.Form.PumpId });
        }

        var request = new ApiSaveCouponBookRequest(
            model.Form.Id,
            model.Form.OwnerId,
            model.Form.PumpId,
            model.Form.BookCode.Trim(),
            model.Form.Denomination,
            model.Form.TotalCoupons,
            model.Form.IssuedToPartyId,
            model.Form.StartSerial,
            model.Form.EndSerial,
            model.Form.IsActive);

        var success = await apiClient.SaveCouponBookAsync(token, request, cancellationToken);
        TempData["CouponBookMessage"] = success.Success ? "Coupon book saved." : (success.ErrorMessage ?? "Unable to save coupon book.");
        return RedirectToAction(nameof(CouponBooks), new { pumpId = model.Form.PumpId });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> SaveCouponTransaction(CouponBooksViewModel model, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null)
        {
            return RedirectToAction("Login", "Account");
        }

        if (model.TxnForm.PumpId <= 0 || model.TxnForm.CouponBookId <= 0 || model.TxnForm.CouponSerialNo <= 0 || model.TxnForm.Amount <= 0)
        {
            TempData["CouponBookMessage"] = "Pump, coupon book, serial no and amount are required.";
            return RedirectToAction(nameof(CouponBooks), new { pumpId = model.TxnForm.PumpId, couponBookId = model.TxnForm.CouponBookId });
        }

        var request = new ApiSaveCouponTransactionRequest(
            model.TxnForm.OwnerId,
            model.TxnForm.PumpId,
            model.TxnForm.CouponBookId,
            model.TxnForm.PartyId,
            model.TxnForm.SalesHeaderId,
            model.TxnForm.CouponSerialNo,
            model.TxnForm.Amount,
            model.TxnForm.Notes,
            model.TxnForm.TxnDateTime.Date == DateTime.Today ? null : model.TxnForm.TxnDateTime);

        var success = await apiClient.SaveCouponTransactionAsync(token, request, cancellationToken);
        TempData["CouponBookMessage"] = success.Success ? "Coupon transaction saved." : (success.ErrorMessage ?? "Unable to save coupon transaction.");
        return RedirectToAction(nameof(CouponBooks), new { pumpId = model.TxnForm.PumpId, couponBookId = model.TxnForm.CouponBookId });
    }

    [HttpGet]
    public async Task<IActionResult> Products(long? editId, long? pumpId, CancellationToken cancellationToken)
    {
        ViewData["Title"] = "Product Management";
        var model = await BuildProductViewModelAsync(editId, pumpId, cancellationToken);
        return View(model);
    }

    /// <summary>
    /// "Aaj ke rate" — pump ke saare fuel ka rate ek hi screen par. Ek pump par
    /// Normal, Premium/XP95, E20, Diesel jaise kai grade hote hain aur roz subah
    /// sabka rate alag aata hai; pehle har ek ke liye Products form alag se
    /// kholna padta tha.
    /// </summary>
    [HttpGet]
    public async Task<IActionResult> DailyRates(long? pumpId, CancellationToken cancellationToken)
    {
        ViewData["Title"] = "Today's Rates";
        var model = await BuildDailyRatesViewModelAsync(pumpId, cancellationToken);
        return View(model);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> SaveDailyRates(DailyRatesViewModel model, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null)
        {
            return RedirectToAction("Login", "Account");
        }

        // Sirf wahi line bhejo jiska rate sach me badla hai. Bina badle wali line
        // bhejne se ProductRateHistory me bekaar entry banti aur "aaj rate badla"
        // wali jaankari jhooti ho jaati.
        var changed = (model.Rates ?? new List<DailyRateRow>())
            .Where(x => x.ProductId > 0 && x.CurrentRate != x.OriginalRate)
            .Select(x => new ApiProductRateLine(x.ProductId, x.CurrentRate))
            .ToList();

        if (changed.Count == 0)
        {
            TempData["DailyRatesMessage"] = "No rate was changed - nothing to save.";
            return RedirectToAction(nameof(DailyRates), new { pumpId = model.PumpId });
        }

        var invalid = changed.FirstOrDefault(x => x.NewRate <= 0);
        if (invalid is not null)
        {
            TempData["DailyRatesMessage"] = "Rate cannot be zero or negative.";
            TempData["DailyRatesError"] = true;
            return RedirectToAction(nameof(DailyRates), new { pumpId = model.PumpId });
        }

        var payload = new ApiUpdateDailyRatesRequest(GetOwnerId(), changed);
        var (success, updated, error) = await apiClient.UpdateDailyRatesAsync(token, payload, cancellationToken);

        if (!success)
        {
            TempData["DailyRatesMessage"] = error ?? "Could not update the rates.";
            TempData["DailyRatesError"] = true;
        }
        else
        {
            TempData["DailyRatesMessage"] = updated == 1
                ? "1 rate updated."
                : $"{updated} rate update ho gaye.";
        }

        return RedirectToAction(nameof(DailyRates), new { pumpId = model.PumpId });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> SaveProduct(ProductManagementViewModel model, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null)
        {
            return RedirectToAction("Login", "Account");
        }

        if (string.IsNullOrWhiteSpace(model.Form.Name) || model.Form.PumpId <= 0 || model.Form.CurrentRate <= 0)
        {
            TempData["ProductMessage"] = "Please provide pump, product name and valid rate.";
            return RedirectToAction(nameof(Products));
        }

        if (!IsOneOf(model.Form.Category, ProductCategories) || !IsOneOf(model.Form.Unit, ProductUnits))
        {
            TempData["ProductMessage"] = "Please pick the category and unit from the list.";
            return RedirectToAction(nameof(Products), new { pumpId = model.Form.PumpId });
        }

        var request = new ApiSaveProductRequest(
            Id: model.Form.Id,
            OwnerId: model.Form.OwnerId,
            PumpId: model.Form.PumpId,
            Name: model.Form.Name.Trim(),
            Category: model.Form.Category,
            Unit: model.Form.Unit,
            CurrentRate: model.Form.CurrentRate,
            HSNCode: model.Form.HSNCode?.Trim(),
            CGSTRate: model.Form.CGSTRate,
            SGSTRate: model.Form.SGSTRate);

        var success = await apiClient.SaveProductAsync(token, request, cancellationToken);
        TempData["ProductMessage"] = success.Success ? "Product saved successfully." : (success.ErrorMessage ?? "Unable to save product.");
        return RedirectToAction(nameof(Products), new { pumpId = model.Form.PumpId });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> DeleteProduct(long id, long pumpId, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null) return RedirectToAction("Login", "Account");

        var result = await apiClient.DeleteProductAsync(token, id, cancellationToken);
        TempData["ProductMessage"] = result.Success ? "Product deleted successfully." : result.ErrorMessage;
        return RedirectToAction(nameof(Products), new { pumpId });
    }

    // ── Din ka collection — Online / Card / udhaar (Section W) ───────────
    //
    // Din ki bikri meter se banti hai, par paisa teen raaston se aata hai. Sirf
    // nakad darj hone se har shift me bada "short" dikhta tha aur usme asli
    // chori chhup jaati thi. Ye chhota form us khaai ko bharta hai.
    [HttpGet]
    public async Task<IActionResult> Collection(long shiftId, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null) return RedirectToAction("Login", "Account");

        ViewData["Title"] = "Day Collection";

        var model = await BuildCollectionViewModelAsync(shiftId, cancellationToken);
        if (model is null) return RedirectToAction(nameof(Shifts));

        model.Message = TempData["CollectionMessage"] as string;
        model.IsError = TempData["CollectionIsError"] is true;
        return View(model);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> SaveCollection(ShiftCollectionForm form, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null) return RedirectToAction("Login", "Account");

        // Khaali line (party chuni hi nahi, ya 0 rupaye) chhod dete hain —
        // form me hamesha ek-do khaali row rehti hain.
        //
        // Ek party ki do line ab JODTE NAHI (Section AK): har line ek parchi hai,
        // apne gaadi number ke saath. Jodne par gaadi number mit jaata.
        var credits = (form.Credits ?? new List<ShiftCollectionCreditForm>())
            .Where(x => x.PartyId > 0 && x.Amount > 0)
            .Select(x => new ApiShiftCollectionCreditLine(x.PartyId, null, x.Amount, x.VehicleNo, x.SlipNote))
            .ToList();

        var result = await apiClient.SaveShiftCollectionAsync(
            token,
            new ApiSaveShiftCollectionRequest(form.ShiftId, form.UpiAmount, form.CardAmount, credits),
            cancellationToken);

        TempData["CollectionMessage"] = result.Success ? "Collection saved." : result.ErrorMessage;
        TempData["CollectionIsError"] = !result.Success;
        return RedirectToAction(nameof(Collection), new { shiftId = form.ShiftId });
    }

    private async Task<ShiftCollectionViewModel?> BuildCollectionViewModelAsync(long shiftId, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null) return null;

        var ownerId = GetOwnerId();

        // Ginti seedha shift ke summary se — usme meter sale aur closing cash
        // dono aate hain. Pehle poori list me se dhoondhta tha, par list par
        // paging lagi hai; purani shift us page me hoti hi nahi thi aur screen
        // chup-chaap Shifts par wapas bhej deti thi.
        var summary = await apiClient.GetShiftCollectionSummaryAsync(token, shiftId, cancellationToken);
        if (summary is null) return null;

        // Label ke liye list dekh lete hain — na mile to bhi kaam rukta nahi.
        //
        // Shift ka pump isi list se milta hai, aur pump se hi party ki list aati hai.
        // Pehle sirf sabse nayi 500 shift dekhi jaati thi: 501vi se purani shift ka
        // collection kholne par pump 0 milta aur udhaar wali party ki list KHAALI aati.
        // Ab shift milne tak aage ke tukde bhi dekhte hain.
        ApiShiftDto? shift = null;
        for (var page = 1; page <= 20 && shift is null; page++)
        {
            var shifts = await apiClient.GetPagedShiftsAsync(token, ownerId, null, null, null, null, page, 500, cancellationToken);
            shift = shifts?.Items?.FirstOrDefault(x => x.Id == shiftId);
            if (shifts?.Items is null || shifts.Items.Count < 500) { break; }
        }

        var collection = await apiClient.GetShiftCollectionAsync(token, shiftId, cancellationToken);
        var parties = shift is null
            ? Array.Empty<ApiPartyDto>()
            : await apiClient.GetAllPartiesAsync(token, ownerId, shift.PumpId, cancellationToken);

        var model = new ShiftCollectionViewModel
        {
            ShiftId = shiftId,
            PumpId = shift?.PumpId ?? 0,
            ShiftLabel = shift is null
                ? $"Shift #{shiftId}"
                : $"{shift.ShiftDate:dd MMM yyyy} - Shift {shift.ShiftNo}",
            MeterSale = summary.TotalMeterSale,
            CashEntered = summary.ActualClosingCash ?? 0,
            Parties = parties,
            Form = new ShiftCollectionForm
            {
                ShiftId = shiftId,
                UpiAmount = collection.UpiAmount,
                CardAmount = collection.CardAmount,
                Credits = collection.Credits
                    .Select(c => new ShiftCollectionCreditForm
                    {
                        PartyId = c.PartyId,
                        Amount = c.Amount,
                        VehicleNo = c.VehicleNo,
                        SlipNote = c.SlipNote
                    })
                    .ToList()
            }
        };

        // Paanch khaali line pehle se — aam din me itni hi udhaar hoti hai, to
        // "Add line" dabane ki zaroorat hi nahi padti.
        for (var i = 0; i < 5; i++)
        {
            model.Form.Credits.Add(new ShiftCollectionCreditForm());
        }

        return model;
    }

    [HttpGet]
    public async Task<IActionResult> Shifts(long? pumpId, DateTime? fromDate, DateTime? toDate, string? searchTerm, int? pageNumber, DateOnly? shiftDate, CancellationToken cancellationToken)
    {
        ViewData["Title"] = "Shift Management";
        var pNum = pageNumber ?? 1;
        // Ek page par 10 shift. Pehle 50 tha — screen par itni lambi list chadhti thi
        // ki page ka neeche wala hissa dikhta hi nahi tha.
        var model = await BuildShiftViewModelAsync(pumpId, fromDate, toDate, searchTerm, pNum, ShiftPageSize, cancellationToken, shiftDate);

        // Dashboard ke "Pending entries" se aaya ho to us din ki tareekh pehle se bhar do,
        // taaki chhoot gayi entry seedha usi din par charh jaye.
        if (shiftDate.HasValue)
        {
            model.OpenShift.ShiftDate = shiftDate.Value;
            model.IsBackdatedEntry = shiftDate.Value < DateOnly.FromDateTime(DateTime.Today);
        }

        return View(model);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> OpenShift(ShiftManagementViewModel model, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null)
        {
            return RedirectToAction("Login", "Account");
        }
        if (model.OpenShift.PumpId <= 0)
        {
            TempData["ShiftMessage"] = "Please select a pump.";
            return RedirectToAction(nameof(Shifts), new { pumpId = model.OpenShift.PumpId });
        }

        // Pehle "operator zaroori hai" ki rok thi, lekin naye pump par koi employee
        // hota hi nahi — is wajah se pehli shift kabhi khul hi nahi paati thi
        // (dropdown 0 bhejta aur FK toot jaati, 500 aata).
        //
        // Ab: kisi ko na chuna jaye to SHIFT KHOLNE WALA hi zimmedar maana jaata hai.
        // Ye zyada sahi hai — chhote pump par malik khud sab dekhta hai, aur "kaun
        // zimmedar tha" ka jawab kabhi khaali nahi rehta (cash kam pade to yahi
        // sabse pehla sawaal hota hai).
        // In-charge ab EMPLOYEE hai (Section K). Kisi ko na chuna gaya ho to
        // OperatorEmployeeId NULL jaata hai aur SP OperatorUserId me shift kholne
        // wale ka login daal deta hai — "kaun zimmedar tha" phir bhi khaali nahi
        // rehta. Yahi pehle wala vyavhaar hai, bas ab source ek hi hai.
        var operatorEmployeeId = model.OpenShift.OperatorEmployeeId is > 0
            ? model.OpenShift.OperatorEmployeeId
            : null;

        var result = await apiClient.OpenShiftAsync(
            token,
            new ApiOpenShiftRequest(
                model.OpenShift.OwnerId,
                model.OpenShift.PumpId,
                operatorEmployeeId is null ? GetUserId() : null,
                model.OpenShift.ShiftDate,
                model.OpenShift.ShiftCode,
                model.OpenShift.OpeningCash,
                model.OpenShift.Notes,
                model.OpenShift.NozzleReadings
                    .Where(x => x.NozzleId > 0)
                    // Aadmi aur chhutta bhi saath hi bhejte hain — form me ye khaane
                    // pehle se the par kahin save hi nahi hote the.
                    .Select(x => new ApiShiftNozzleOpenReading(
                        x.NozzleId, x.ProductId, x.OpeningReading,
                        x.AttendantEmployeeId is > 0 ? x.AttendantEmployeeId : null,
                        x.FloatGiven))
                    .ToList(),
                operatorEmployeeId,
                // "Meter was changed" tick kiya ho to hi rok hatti hai (Section R).
                model.OpenShift.AllowMeterGap),
            cancellationToken);

        TempData["ShiftMessage"] = result.Success ? "Shift opened successfully." : result.ErrorMessage;
        return RedirectToAction(nameof(Shifts), new { pumpId = model.OpenShift.PumpId });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> CloseShift(ShiftManagementViewModel model,
        [FromServices] Microsoft.Extensions.Localization.IStringLocalizer<SharedResource> localizer,
        CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null)
        {
            return RedirectToAction("Login", "Account");
        }

        var request = new ApiCloseShiftRequest(
            model.CloseShift.Id,
            model.CloseShift.ClosingCash,
            model.CloseShift.Notes,
            model.CloseShift.NozzleReadings
                .Where(x => x.NozzleId > 0)
                .Select(x => new ApiShiftNozzleCloseReading(x.NozzleId, x.ClosingReading, x.TestingLoss))
                .ToList());
        var result = await apiClient.CloseShiftAsync(token, model.CloseShift.Id, request, cancellationToken);
        if (!result.Success)
        {
            TempData["ShiftMessage"] = result.ErrorMessage;
            return RedirectToAction(nameof(Shifts));
        }

        var message = localizer["Shift closed successfully."].Value;

        // Tank ki dip - shift band hone ke BAAD hi (Section AB). Book stock me
        // is shift ki bikri tabhi ghat-ti hai; pehle daalne par farak galat
        // aata tha. Jis tank ka Actual Stock khaali hai, wo chhod dete hain.
        var dips = (model.CloseShift.Dips ?? new List<ShiftClosingDipForm>())
            .Where(x => x.TankId > 0 && (x.ActualStock ?? 0) > 0)
            .Select(x => new ApiShiftClosingDipInput(x.TankId, x.DipCm, x.ActualStock!.Value))
            .ToList();

        if (dips.Count > 0)
        {
            var dipResult = await apiClient.SaveShiftClosingDipsAsync(
                token, model.CloseShift.Id, new ApiSaveShiftClosingDipsRequest(dips), cancellationToken);

            if (dipResult.Success)
            {
                // "HSD Tank: +4.74 L" - wahi number jo DSR me Variation me aayega.
                var parts = dipResult.Saved.Select(x =>
                    $"{x.TankName}: {(x.Variance > 0 ? "+" : "")}{x.Variance:0.##} L");
                message += " " + localizer["Dip saved"].Value + " - " + string.Join(", ", parts) + ".";
            }
            else
            {
                // Shift to band ho chuki hai - use ulta nahi karte. Bas saaf batao
                // ki dip nahi gayi, taaki Dip Testing se daal sakein.
                message += " " + localizer["But the dip was not saved"].Value + ": " + dipResult.ErrorMessage;
            }
        }

        TempData["ShiftMessage"] = message;
        return RedirectToAction(nameof(Shifts));
    }

    /// <summary>
    /// Shift kholte waqt chuni hui tareekh ki jaanch (back-date).
    ///
    /// Do galtiyan jo form rok nahi paata tha:
    ///  1. Beech ke din chhoot gaye aur aage ka din khol diya — opening pichhle
    ///     bhare hue din se aati hai, to chhoote dinon ki bikri bhi isi din me jud
    ///     jaati hai. Baad me wo din bharo to bikri DO BAAR gin jaati hai.
    ///  2. Aage ke din ki shift pehle se hai aur beech me din ghusa diya — us aage
    ///     wale din ki opening galat ho jaati hai (13 Sep wali gadbad yahi thi).
    /// Rokta nahi (pump band bhi reh sakta hai), bas saaf bata deta hai.
    /// </summary>
    [HttpGet]
    public async Task<IActionResult> ShiftDateCheck(long pumpId, string date, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null) return Unauthorized();
        if (pumpId <= 0 || !DateOnly.TryParse(date, out var day)) return Json(new { });

        var shifts = await apiClient.GetShiftsAsync(
            token, GetOwnerId(), pumpId, day.AddDays(-60), day.AddDays(60), 500, cancellationToken);

        DateOnly? prev = shifts.Where(s => s.ShiftDate < day)
                               .Select(s => (DateOnly?)s.ShiftDate)
                               .DefaultIfEmpty()
                               .Max();
        var later = shifts.Where(s => s.ShiftDate > day).OrderBy(s => s.ShiftDate).FirstOrDefault();
        var gapDays = prev is DateOnly p ? day.DayNumber - p.DayNumber - 1 : 0;
        var today = DateOnly.FromDateTime(DateTime.Today);

        return Json(new
        {
            gapDays,
            gapFrom = gapDays > 0 ? prev!.Value.AddDays(1).ToString("dd-MM-yyyy") : null,
            gapTo = gapDays > 0 ? day.AddDays(-1).ToString("dd-MM-yyyy") : null,
            laterDate = later?.ShiftDate.ToString("dd-MM-yyyy"),
            isFuture = day > today,
            isPast = day < today
        });
    }

    /// <summary>Close Shift form khulte hi - pump ke tank, book stock (shift ki bikri ke bina), pehle se padi dip.</summary>
    [HttpGet]
    public async Task<IActionResult> ShiftClosingDips(long shiftId, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null) return Unauthorized();

        var rows = await apiClient.GetShiftClosingDipsAsync(token, shiftId, cancellationToken);
        return Json(rows);
    }

    /// <summary>Dip Testing ka Book Stock - DSR wala hisaab (Section AB).</summary>
    [HttpGet]
    public async Task<IActionResult> GetDipBookStock(long tankId, string date, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null) return Unauthorized();

        if (!DateOnly.TryParse(date, out var parsedDate))
        {
            parsedDate = DateOnly.FromDateTime(DateTime.Today);
        }

        var stock = await apiClient.GetDipBookStockAsync(token, tankId, parsedDate, cancellationToken);
        return Json(new { stock });
    }

    public sealed record CashDenominationLineInput(int Denomination, int Pieces);
    public sealed record SaveCashDenominationInput(long PumpId, List<CashDenominationLineInput> Lines);

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> SaveShiftCashDenomination(long shiftId, [FromBody] SaveCashDenominationInput input, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null)
        {
            return Unauthorized();
        }

        var request = new ApiSaveCashDenominationRequest(
            GetOwnerId(),
            input.PumpId,
            input.Lines.Select(x => new ApiCashDenominationLine(x.Denomination, x.Pieces)).ToList());

        var result = await apiClient.SaveShiftCashDenominationAsync(token, shiftId, request, cancellationToken);
        return Json(new { success = result.Success, totalCounted = result.TotalCounted, message = result.ErrorMessage });
    }

    [HttpGet]
    public async Task<IActionResult> ShiftNozzleReadings(long shiftId, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null)
        {
            return Unauthorized();
        }

        var items = await apiClient.GetShiftNozzleReadingsAsync(token, shiftId, cancellationToken);
        return Json(items);
    }

    [HttpGet]
    public async Task<IActionResult> GetProductRateHistory(long productId, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null) return Unauthorized();

        var history = await apiClient.GetProductRateHistoryAsync(token, productId, cancellationToken);
        return Json(history);
    }

    [HttpGet]
    public async Task<IActionResult> ShiftSummary(long shiftId, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null)
        {
            return Unauthorized();
        }

        var summary = await apiClient.GetShiftCollectionSummaryAsync(token, shiftId, cancellationToken);
        return Json(summary);
    }

    /// <summary>Returns the last closed shift's closing reading per nozzle for a pump — used to auto-fill Open Shift form.</summary>
    [HttpGet]
    public async Task<IActionResult> LastNozzleReadings(long pumpId, DateOnly? beforeDate, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null) return Unauthorized();

        // beforeDate: form me chuni hui shift ki tareekh. Tareekh badalne par
        // page dobara khole bina sahi opening reading mangwa lete hain.
        var items = await apiClient.GetLastNozzleReadingsAsync(token, pumpId, beforeDate, cancellationToken);
        return Json(items);
    }

    [HttpGet]
    // Tareekh ke do-do naam jaanbujh kar:
    //   Page ka apna khoj-form aur pager ke link `fromDate` / `toDate` bhejte hain, par ye
    //   action sirf `dateFrom` / `dateTo` sunta tha — naam mile hi nahi, to tareekh ki khoj
    //   chupchaap andekhi ho jaati thi (list wahi ki wahi, khaane dobara khaali).
    //   `dateFrom` / `dateTo` purane link (bookmark) ke liye rakhe hain.
    public async Task<IActionResult> Sales(long? pumpId, DateOnly? fromDate, DateOnly? toDate, DateOnly? dateFrom, DateOnly? dateTo, string? searchTerm, int? pageNumber, CancellationToken cancellationToken)
    {
        ViewData["Title"] = "Sales Management";
        var from = fromDate ?? dateFrom;
        var to = toDate ?? dateTo;
        var model = await BuildSalesViewModelAsync(
            pumpId,
            from?.ToDateTime(TimeOnly.MinValue),
            // Din ke ANT tak: sp_Sales_List `BillDateTime <= @ToDate` lagata hai. Raat 12:00
            // bhejne par "10 tak" chunne se 10 tareekh ke hi saare bill bahar ho jaate.
            to?.ToDateTime(TimeOnly.MaxValue),
            searchTerm,
            Math.Max(1, pageNumber ?? 1),
            ListPageSize,
            cancellationToken);
        return View(model);
    }

    [HttpGet]
    public async Task<IActionResult> ExportSalesCsv(long pumpId, DateOnly? dateFrom, DateOnly? dateTo, string? searchTerm, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null) return Unauthorized();

        var ownerId = GetOwnerId();
        var from = dateFrom?.ToDateTime(TimeOnly.MinValue);
        var to = dateTo?.ToDateTime(TimeOnly.MaxValue);
        
        // Use a large page size to get all data for export
        var salesResponse = await apiClient.GetSalesAsync(token, ownerId, pumpId, from, to, searchTerm, 1, 10000, cancellationToken);
        
        var builder = new System.Text.StringBuilder();
        builder.AppendLine("Date,Bill No,Payment Mode,Vehicle No,Customer,Attendant,Amount");
        foreach (var sale in salesResponse.Items)
        {
            var date = sale.BillDateTime.ToString("dd-MM-yyyy HH:mm");
            var cust = sale.CustomerName?.Replace("\"", "\"\"") ?? "";
            var att = sale.AttendantName?.Replace("\"", "\"\"") ?? "";
            builder.AppendLine($"{date},{sale.BillNo},{sale.PaymentMode},{sale.VehicleNo},\"{cust}\",\"{att}\",{sale.TotalAmount:0.00}");
        }

        var fileName = $"Sales_{pumpId}_{dateFrom:yyyyMMdd}_to_{dateTo:yyyyMMdd}.csv";
        return File(System.Text.Encoding.UTF8.GetBytes(builder.ToString()), "text/csv", fileName);
    }



    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> SaveSale(SalesManagementViewModel model, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null)
        {
            return RedirectToAction("Login", "Account");
        }

        var validItems = model.Form.Items
            .Where(x => x.ProductId > 0 && x.Quantity > 0 && x.Rate > 0)
            .ToList();

        if (model.Form.PumpId <= 0 || model.Form.ShiftId <= 0 || validItems.Count == 0)
        {
            TempData["SalesMessage"] = "Pump, open shift and at least one valid line item are required.";
            return RedirectToAction(nameof(Sales), new { pumpId = model.Form.PumpId });
        }

        if (!IsOneOf(model.Form.PaymentMode, SalePaymentModes))
        {
            TempData["SalesMessage"] = "Please pick the payment mode from the list.";
            return RedirectToAction(nameof(Sales), new { pumpId = model.Form.PumpId });
        }

        if (string.Equals(model.Form.PaymentMode, "Credit", StringComparison.OrdinalIgnoreCase) && (model.Form.PartyId ?? 0) <= 0)
        {
            TempData["SalesMessage"] = "For Credit sale, selecting a party is required.";
            return RedirectToAction(nameof(Sales), new { pumpId = model.Form.PumpId });
        }

        var ownerId = GetOwnerId();
        var products = await apiClient.GetProductsAsync(token, ownerId, model.Form.PumpId, cancellationToken);

        var requestItems = new List<ApiSaleItemRequest>();
        foreach (var item in validItems)
        {
            var product = products.FirstOrDefault(p => p.Id == item.ProductId);
            var cgstRate = product?.CGSTRate ?? 0;
            var sgstRate = product?.SGSTRate ?? 0;
            var totalTaxRate = cgstRate + sgstRate;
            
            // Reverse calculation: TotalRate = BaseRate + (BaseRate * TaxRate / 100)
            // BaseRate = TotalRate / (1 + TaxRate / 100)
            var totalAmount = item.Quantity * item.Rate;
            var baseAmount = totalTaxRate > 0 ? totalAmount / (1 + (totalTaxRate / 100m)) : totalAmount;
            var cgstAmount = totalTaxRate > 0 ? baseAmount * (cgstRate / 100m) : 0;
            var sgstAmount = totalTaxRate > 0 ? baseAmount * (sgstRate / 100m) : 0;

            requestItems.Add(new ApiSaleItemRequest(
                item.ProductId,
                item.NozzleNo,
                item.Quantity,
                item.Rate,
                Math.Round(baseAmount, 2),
                Math.Round(cgstAmount, 2),
                Math.Round(sgstAmount, 2)
            ));
        }

        var request = new ApiSaveSaleRequest(
            model.Form.OwnerId,
            model.Form.PumpId,
            model.Form.ShiftId,
            model.Form.PaymentMode,
            model.Form.PartyId,
            model.Form.VehicleNo,
            model.Form.CustomerName,
            model.Form.AttendantName,
            requestItems,
            // Aaj ki hi tareekh ho to NULL bhejo (server apna waqt lagayega); purani
            // tareekh ho to wahi bhejo — chhoot gayi entries ke liye.
            model.Form.BillDateTime.Date == DateTime.Today ? null : model.Form.BillDateTime);

        var saleResult = await apiClient.SaveSaleAsync(token, request, cancellationToken);
        if (saleResult.Id is null)
        {
            TempData["SalesMessage"] = saleResult.ErrorMessage ?? "Unable to save sale.";
            return RedirectToAction(nameof(Sales), new { pumpId = model.Form.PumpId });
        }

        var receipt = await apiClient.GenerateReceiptAsync(token, saleResult.Id.Value, cancellationToken);
        if (receipt is not null)
        {
            TempData["SalesMessage"] = $"Sale saved. Receipt #{receipt.ReceiptNo} generated.";
            TempData["LatestReceipt"] = System.Text.Json.JsonSerializer.Serialize(receipt);
        }
        else
        {
            TempData["SalesMessage"] = "Sale saved, but receipt generation failed.";
        }

        return RedirectToAction(nameof(Sales), new { pumpId = model.Form.PumpId });
    }

    [HttpGet]
    public async Task<IActionResult> PrintReceipt(long saleId, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null) return Unauthorized();

        var dto = await apiClient.GenerateReceiptAsync(token, saleId, cancellationToken);
        if (dto is null) return NotFound();

        return View("ReceiptPrint", dto);
    }

    [HttpGet]
    public async Task<IActionResult> Users(long? editId, CancellationToken cancellationToken)
    {
        ViewData["Title"] = "User Management";
        var model = await BuildUserViewModelAsync(editId, cancellationToken);
        return View(model);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> SaveUser(UserManagementViewModel model, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null)
        {
            return RedirectToAction("Login", "Account");
        }

        var isNew = model.Form.Id is null or 0;

        if (string.IsNullOrWhiteSpace(model.Form.FullName) ||
            string.IsNullOrWhiteSpace(model.Form.Username) ||
            model.Form.RoleId <= 0)
        {
            TempData["UserMessage"] = "Please provide full name, username and role.";
            return RedirectToAction(nameof(Users));
        }

        if (isNew && string.IsNullOrWhiteSpace(model.Form.Password))
        {
            TempData["UserMessage"] = "Password is required for new users.";
            return RedirectToAction(nameof(Users));
        }

        // For edit: if password is blank, send a placeholder that the API/SP should ignore
        var passwordToSend = string.IsNullOrWhiteSpace(model.Form.Password)
            ? "***UNCHANGED***"
            : model.Form.Password;

        var request = new ApiSaveUserRequest(
            model.Form.Id,
            model.Form.OwnerId,
            model.Form.FullName.Trim(),
            model.Form.Username.Trim(),
            passwordToSend,
            model.Form.Mobile,
            model.Form.RoleId);

        var success = await apiClient.SaveUserAsync(token, request, cancellationToken);
        TempData["UserMessage"] = success.Success ? "User saved successfully." : (success.ErrorMessage ?? "Unable to save user.");
        return RedirectToAction(nameof(Users));
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> DeleteUser(long id, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null) return RedirectToAction("Login", "Account");

        var result = await apiClient.DeleteUserAsync(token, id, cancellationToken);
        TempData["UserMessage"] = result.Success ? "User deleted successfully." : result.ErrorMessage;
        return RedirectToAction(nameof(Users));
    }

    [HttpGet]
    // ================= Wallet (message credits) =================

    public async Task<IActionResult> Wallet(CancellationToken cancellationToken)
    {
        ViewData["Title"] = "Message Balance";

        var token = GetToken();
        if (token is null)
        {
            return RedirectToAction("Login", "Account");
        }

        return View(new WalletViewModel
        {
            Wallet = await apiClient.GetWalletAsync(token, cancellationToken),
            Ledger = await apiClient.GetWalletLedgerAsync(token, cancellationToken),
            Recharges = await apiClient.GetMyRechargesAsync(token, cancellationToken),
            Message = TempData["WalletMessage"] as string,
            IsError = TempData["WalletIsError"] is true
        });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> RequestRecharge(decimal amount, string? upiReference, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null)
        {
            return RedirectToAction("Login", "Account");
        }

        var result = await apiClient.RequestRechargeAsync(token, amount, upiReference, cancellationToken);
        TempData["WalletMessage"] = result.Success
            ? "Recharge request sent. Credits will be added once the payment is checked."
            : (result.ErrorMessage ?? "Could not submit the recharge request.");
        TempData["WalletIsError"] = !result.Success;
        return RedirectToAction(nameof(Wallet));
    }

    // ================= Settings > Alerts =================
    // Owner khud tay kare ki kaunse sandesh chahiye aur kis number par.

    public async Task<IActionResult> Alerts(CancellationToken cancellationToken)
    {
        ViewData["Title"] = "Alert Settings";

        var token = GetToken();
        if (token is null)
        {
            return RedirectToAction("Login", "Account");
        }

        var data = await apiClient.GetOwnerAlertsAsync(token, cancellationToken);
        return View(new OwnerAlertViewModel
        {
            Mobile = data.Mobile,
            Alerts = data.Alerts,
            Message = TempData["AlertMessage"] as string,
            IsError = TempData["AlertIsError"] is true
        });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> SaveAlertMobile(string? mobile, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null)
        {
            return RedirectToAction("Login", "Account");
        }

        var result = await apiClient.SaveOwnerAlertMobileAsync(token, mobile, cancellationToken);
        TempData["AlertMessage"] = result.Success
            ? "Mobile number saved. Alerts will now go to this number."
            : (result.ErrorMessage ?? "Could not save the mobile number.");
        TempData["AlertIsError"] = !result.Success;
        return RedirectToAction(nameof(Alerts));
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> SaveAlertSetting(string alertKey, bool isEnabled, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null)
        {
            return RedirectToAction("Login", "Account");
        }

        var result = await apiClient.SaveOwnerAlertAsync(token, alertKey, isEnabled, cancellationToken);
        TempData["AlertMessage"] = result.Success
            ? (isEnabled ? "Alert turned on." : "Alert turned off.")
            : (result.ErrorMessage ?? "Could not save the alert setting.");
        TempData["AlertIsError"] = !result.Success;
        return RedirectToAction(nameof(Alerts));
    }

    // ================= Staff — employee + login ek hi form se =================
    // Purane /Operations/Users aur /Operations/Employees page waise ke waise chalte
    // rahenge (owner/auditor jaise log jo employee nahi hain, unke liye Users page
    // hi chahiye). Ye page un dono ka kaam ek jagah kar deta hai.

    public async Task<IActionResult> Staff(long? pumpId, long? editId, CancellationToken cancellationToken)
    {
        ViewData["Title"] = "Staff Management";
        var model = await BuildStaffViewModelAsync(pumpId, editId, cancellationToken);
        return View(model);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> SaveStaff(StaffManagementViewModel model, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null)
        {
            return RedirectToAction("Login", "Account");
        }

        var form = model.Form;

        if (form.PumpId <= 0 || string.IsNullOrWhiteSpace(form.FullName))
        {
            TempData["StaffMessage"] = "Pump and full name are required.";
            return RedirectToAction(nameof(Staff), new { pumpId = form.PumpId, editId = form.Id });
        }

        if (form.WantsLogin)
        {
            if (string.IsNullOrWhiteSpace(form.Username))
            {
                TempData["StaffMessage"] = "Username is required when you give this person a login.";
                return RedirectToAction(nameof(Staff), new { pumpId = form.PumpId, editId = form.Id });
            }

            if (form.RoleId is null or 0)
            {
                TempData["StaffMessage"] = "Please pick a role for this login.";
                return RedirectToAction(nameof(Staff), new { pumpId = form.PumpId, editId = form.Id });
            }

            // Naya login banate waqt password zaroori hai. Purane login ko edit karte
            // waqt khaali chhodna theek hai — placeholder bhejte hain aur SP purana
            // hash waisa hi rehne deta hai (Section L1 ka fix).
            if (string.IsNullOrWhiteSpace(form.Password) && !form.HasExistingLogin)
            {
                TempData["StaffMessage"] = "A password is required when creating a new login.";
                return RedirectToAction(nameof(Staff), new { pumpId = form.PumpId, editId = form.Id });
            }
        }

        var password = form.WantsLogin
            ? (string.IsNullOrWhiteSpace(form.Password) ? "***UNCHANGED***" : form.Password)
            : null;

        // Naya employee: code SAVE ke waqt fresh generate karo, form se aaya hua mat lo.
        // Agar 2 log ek saath form kholein to dono ko wahi code dikhta — ek save kare,
        // doosra save kare, to duplicate ban jaata. Isliye save ke waqt dubara list
        // laate hain aur naya unique code nikalte hain. Edit me purana code rehta hai.
        var employeeCode = form.EmployeeCode;
        if (form.Id is null or 0)
        {
            var ownerId = GetOwnerId();
            var currentStaff = await apiClient.GetStaffAsync(token, ownerId, form.PumpId, cancellationToken);
            employeeCode = GenerateNextEmployeeCode(currentStaff);
        }

        var result = await apiClient.SaveStaffAsync(
            token,
            new ApiSaveStaffRequest(
                form.Id,
                GetOwnerId(),
                form.PumpId,
                employeeCode,
                form.FullName,
                form.Mobile,
                form.JoinDate,
                form.Designation,
                form.MonthlySalary,
                form.IsActive,
                form.WantsLogin,
                form.WantsLogin ? form.Username : null,
                password,
                form.WantsLogin ? form.RoleId : null),
            cancellationToken);

        TempData["StaffMessage"] = result.Success
            ? (form.WantsLogin ? "Saved. This person can now sign in." : "Saved.")
            : result.ErrorMessage;

        return RedirectToAction(nameof(Staff), new { pumpId = form.PumpId });
    }

    public async Task<IActionResult> Employees(long? pumpId, long? editId, CancellationToken cancellationToken)
    {
        ViewData["Title"] = "Employee Management";
        var model = await BuildEmployeeViewModelAsync(pumpId, editId, cancellationToken);
        return View(model);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> SaveEmployee(EmployeeManagementViewModel model, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null)
        {
            return RedirectToAction("Login", "Account");
        }

        if (model.Form.PumpId <= 0 || string.IsNullOrWhiteSpace(model.Form.FullName))
        {
            TempData["EmployeeMessage"] = "Pump and full name are required.";
            return RedirectToAction(nameof(Employees), new { pumpId = model.Form.PumpId });
        }

        // Staff jaisa hi — naye employee ke liye code save ke waqt fresh generate karo.
        var employeeCode = model.Form.EmployeeCode;
        if (model.Form.Id is null or 0)
        {
            var currentEmployees = await apiClient.GetEmployeesAsync(token, model.Form.OwnerId, model.Form.PumpId, cancellationToken);
            employeeCode = GenerateNextEmployeeCode(currentEmployees);
        }

        var request = new ApiSaveEmployeeRequest(
            model.Form.Id,
            model.Form.OwnerId,
            model.Form.PumpId,
            model.Form.UserId,
            employeeCode,
            model.Form.FullName.Trim(),
            model.Form.Mobile,
            model.Form.JoinDate,
            model.Form.Designation,
            model.Form.MonthlySalary,
            model.Form.IsActive);

        var result = await apiClient.SaveEmployeeAsync(token, request, cancellationToken);
        TempData["EmployeeMessage"] = result.Success ? "Employee saved successfully." : result.ErrorMessage;
        return RedirectToAction(nameof(Employees), new { pumpId = model.Form.PumpId });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> DeleteEmployee(long id, long pumpId, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null) return RedirectToAction("Login", "Account");

        var result = await apiClient.DeleteEmployeeAsync(token, id, cancellationToken);
        TempData["EmployeeMessage"] = result.Success ? "Employee deleted successfully." : result.ErrorMessage;
        return RedirectToAction(nameof(Employees), new { pumpId = pumpId });
    }

    [HttpGet]
    public async Task<IActionResult> Salary(long? pumpId, int? salaryYear, int? salaryMonth, CancellationToken cancellationToken)
    {
        ViewData["Title"] = "Salary Register";
        var model = await BuildSalaryViewModelAsync(pumpId, salaryYear, salaryMonth, cancellationToken);
        return View(model);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> SaveSalary(SalaryManagementViewModel model, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null)
        {
            return RedirectToAction("Login", "Account");
        }

        if (model.Form.PumpId <= 0 || model.Form.EmployeeId <= 0 || model.Form.Amount <= 0)
        {
            TempData["SalaryMessage"] = "Pump, employee and amount are required.";
            return RedirectToAction(nameof(Salary), new { pumpId = model.Form.PumpId, salaryYear = model.Form.SalaryYear, salaryMonth = model.Form.SalaryMonth });
        }

        if (!IsOneOf(model.Form.PaymentMode, CashPaymentModes))
        {
            TempData["SalaryMessage"] = "Please pick the payment mode from the list.";
            return RedirectToAction(nameof(Salary), new { pumpId = model.Form.PumpId, salaryYear = model.Form.SalaryYear, salaryMonth = model.Form.SalaryMonth });
        }

        var request = new ApiSaveSalaryPaymentRequest(
            model.Form.Id,
            model.Form.OwnerId,
            model.Form.PumpId,
            model.Form.EmployeeId,
            model.Form.SalaryYear,
            model.Form.SalaryMonth,
            model.Form.Amount,
            model.Form.PaidOn,
            model.Form.PaymentMode,
            model.Form.ReferenceNo,
            model.Form.Notes);

        var result = await apiClient.SaveSalaryPaymentAsync(token, request, cancellationToken);
        TempData["SalaryMessage"] = result.Success ? "Salary payment saved successfully." : result.ErrorMessage;
        return RedirectToAction(nameof(Salary), new { pumpId = model.Form.PumpId, salaryYear = model.Form.SalaryYear, salaryMonth = model.Form.SalaryMonth });
    }

    [HttpGet]
    public async Task<IActionResult> Roles(long? editId, CancellationToken cancellationToken)
    {
        ViewData["Title"] = "Role Management";
        var model = await BuildRoleViewModelAsync(editId, cancellationToken);
        return View(model);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> SaveRole(RoleManagementViewModel model, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null)
        {
            return RedirectToAction("Login", "Account");
        }

        if (string.IsNullOrWhiteSpace(model.Form.Name))
        {
            TempData["RoleMessage"] = "Role name is required.";
            return RedirectToAction(nameof(Roles));
        }

        var request = new ApiSaveRoleRequest(
            model.Form.Id,
            model.Form.OwnerId,
            model.Form.Name.Trim(),
            model.Form.IsSystem);

        var success = await apiClient.SaveRoleAsync(token, request, cancellationToken);
        TempData["RoleMessage"] = success.Success ? "Role saved successfully." : (success.ErrorMessage ?? "Unable to save role.");
        return RedirectToAction(nameof(Roles));
    }

    [HttpGet]
    public async Task<IActionResult> RolePermissions(long roleId, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null)
        {
            return RedirectToAction("Login", "Account");
        }
        var ownerId = GetOwnerId();

        var roles = await apiClient.GetRolesAsync(token, ownerId, cancellationToken);
        var role = roles.FirstOrDefault(r => r.Id == roleId);
        if (role == null) return RedirectToAction(nameof(Roles));

        var allMenus = await apiClient.GetAllMenusAsync(token, cancellationToken);
        var roleMenus = await apiClient.GetRoleMenusAsync(token, roleId, cancellationToken);

        var model = new RolePermissionsViewModel
        {
            RoleId = roleId,
            RoleName = role.Name
        };

        foreach (var m in allMenus)
        {
            var rm = roleMenus.FirstOrDefault(x => x.MenuId == m.Id);
            model.Menus.Add(new RoleMenuForm
            {
                MenuId = m.Id,
                MenuName = m.MenuName,
                Route = m.Route,
                Icon = m.Icon,
                CanView = rm?.CanView ?? false,
                CanCreate = rm?.CanCreate ?? false,
                CanEdit = rm?.CanEdit ?? false,
                CanDelete = rm?.CanDelete ?? false
            });
        }

        return View(model);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> SaveRolePermissions(RolePermissionsViewModel model, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null)
        {
            return RedirectToAction("Login", "Account");
        }

        var request = new ApiSaveRoleMenusRequest(
            model.RoleId,
            model.Menus.Select(m => new ApiRoleMenuRequestDto(
                m.MenuId,
                m.CanView,
                m.CanCreate,
                m.CanEdit,
                m.CanDelete
            )).ToList()
        );

        await apiClient.SaveRoleMenusAsync(token, request, cancellationToken);
        TempData["RoleMessage"] = "Permissions updated successfully.";
        return RedirectToAction(nameof(Roles));
    }

    private async Task<PumpManagementViewModel> BuildPumpViewModelAsync(long? editId, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null)
        {
            return new PumpManagementViewModel();
        }

        var ownerId = GetOwnerId();
        var pumps = await apiClient.GetPumpsAsync(token, ownerId, cancellationToken);
        var editItem = editId is null ? null : pumps.FirstOrDefault(x => x.Id == editId.Value);

        return new PumpManagementViewModel
        {
            Form = new PumpForm
            {
                Id = editItem?.Id,
                OwnerId = ownerId,
                Name = editItem?.Name ?? string.Empty,
                City = editItem?.City,
                Address = editItem?.Address,
                ContactNo = editItem?.ContactNo,
                GSTIN = editItem?.GSTIN
            },
            Pumps = pumps,
            Message = TempData["PumpMessage"] as string
        };
    }

    private async Task<NozzleManagementViewModel> BuildNozzleViewModelAsync(long? editId, long? pumpId, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null)
        {
            return new NozzleManagementViewModel();
        }

        var ownerId = GetOwnerId();
        var pumps = await apiClient.GetPumpsAsync(token, ownerId, cancellationToken);
        var selectedPumpId = pumpId ?? pumps.FirstOrDefault()?.Id ?? 0;
        
        var products = await apiClient.GetProductsAsync(token, ownerId, selectedPumpId > 0 ? selectedPumpId : null, cancellationToken);
        var nozzles = await apiClient.GetNozzlesAsync(token, ownerId, selectedPumpId > 0 ? selectedPumpId : null, cancellationToken);
        var tanks = selectedPumpId > 0
            ? (await apiClient.GetTanksAsync(token, ownerId, selectedPumpId, null, 1, 500, cancellationToken)).Items
            : Array.Empty<ApiTankDto>();

        var editItem = editId is null ? null : nozzles.FirstOrDefault(x => x.Id == editId.Value);

        return new NozzleManagementViewModel
        {
            Form = new NozzleForm
            {
                Id = editItem?.Id,
                OwnerId = ownerId,
                PumpId = selectedPumpId,
                ProductId = editItem?.ProductId ?? products.FirstOrDefault()?.Id ?? 0,
                NozzleCode = editItem?.NozzleCode ?? string.Empty,
                TankId = editItem?.TankId
            },
            Pumps = pumps,
            Products = products,
            Nozzles = nozzles,
            Tanks = tanks,
            Message = TempData["NozzleMessage"] as string
        };
    }

    private async Task<NozzleCashViewModel> BuildNozzleCashViewModelAsync(long? pumpId, long? shiftId, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null)
        {
            return new NozzleCashViewModel();
        }

        var ownerId = GetOwnerId();
        var pumps = await apiClient.GetPumpsAsync(token, ownerId, cancellationToken);
        var selectedPumpId = pumpId ?? pumps.FirstOrDefault()?.Id ?? 0;

        // Purani shift ka cash bhi baad me liya ja sakta hai, isliye 3 mahine peeche
        // tak. (Pehle "saari shift" maangi jaati thi jo chupchaap 50 par kat jaati
        // thi — usse purani shift dropdown me aati hi nahi thi.)
        var shifts = (await apiClient.GetShiftsAsync(
                token, ownerId, selectedPumpId > 0 ? selectedPumpId : null,
                DateOnly.FromDateTime(DateTime.Today.AddMonths(-3)),
                DateOnly.FromDateTime(DateTime.Today),
                500, cancellationToken))
            .OrderByDescending(x => x.ShiftDate).ThenByDescending(x => x.Id)
            .ToList();

        var selectedShiftId = shiftId ?? 0;
        var shiftRows = selectedShiftId > 0
            ? await apiClient.GetShiftNozzleCashAsync(token, selectedShiftId, cancellationToken)
            : Array.Empty<ApiNozzleCashDto>();

        var employees = selectedPumpId > 0
            ? await apiClient.GetEmployeesAsync(token, ownerId, selectedPumpId, cancellationToken)
            : Array.Empty<ApiEmployeeDto>();

        var pending = await apiClient.GetPendingNozzleCashAsync(token, selectedPumpId, null, null, cancellationToken);

        return new NozzleCashViewModel
        {
            OwnerId = ownerId,
            PumpId = selectedPumpId,
            Pumps = pumps,
            Employees = employees.Where(x => x.IsActive).ToList(),
            SelectedShiftId = selectedShiftId,
            Shifts = shifts,
            ShiftRows = shiftRows,
            Pending = pending,
            Message = TempData["NozzleCashMessage"] as string,
            IsError = TempData["NozzleCashError"] is bool f && f
        };
    }

    private async Task<DailyRatesViewModel> BuildDailyRatesViewModelAsync(long? pumpId, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null)
        {
            return new DailyRatesViewModel();
        }

        var ownerId = GetOwnerId();
        var pumps = await apiClient.GetPumpsAsync(token, ownerId, cancellationToken);
        var selectedPumpId = pumpId ?? pumps.FirstOrDefault()?.Id ?? 0;

        var rates = await apiClient.GetDailyRatesAsync(token, ownerId, selectedPumpId > 0 ? selectedPumpId : null, cancellationToken);

        return new DailyRatesViewModel
        {
            OwnerId = ownerId,
            PumpId = selectedPumpId,
            Pumps = pumps,
            Rates = rates.Select(x => new DailyRateRow
            {
                ProductId = x.Id,
                Name = x.Name,
                Category = x.Category,
                Unit = x.Unit,
                PumpName = x.PumpName,
                CurrentRate = x.CurrentRate,
                // OriginalRate se hi pata chalega ki user ne kaunsi line chhui.
                OriginalRate = x.CurrentRate,
                PreviousRate = x.PreviousRate,
                LastChangedOn = x.LastChangedOn
            }).ToList(),
            Message = TempData["DailyRatesMessage"] as string,
            IsError = TempData["DailyRatesError"] is bool flag && flag
        };
    }

    private async Task<ProductManagementViewModel> BuildProductViewModelAsync(long? editId, long? pumpId, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null)
        {
            return new ProductManagementViewModel();
        }

        var ownerId = GetOwnerId();
        var pumps = await apiClient.GetPumpsAsync(token, ownerId, cancellationToken);
        var selectedPumpId = pumpId ?? pumps.FirstOrDefault()?.Id ?? 0;
        
        var products = await apiClient.GetProductsAsync(token, ownerId, selectedPumpId > 0 ? selectedPumpId : null, cancellationToken);
        
        var defaultRate = products.FirstOrDefault()?.CurrentRate ?? 0;
        var editItem = editId is null ? null : products.FirstOrDefault(x => x.Id == editId.Value);

        return new ProductManagementViewModel
        {
            Form = new ProductForm
            {
                Id = editItem?.Id,
                OwnerId = ownerId,
                PumpId = editItem?.PumpId ?? selectedPumpId,
                Name = editItem?.Name ?? string.Empty,
                Category = editItem?.Category ?? "Petrol",
                Unit = editItem?.Unit ?? "Litre",
                CurrentRate = editItem?.CurrentRate ?? defaultRate,
                HSNCode = editItem?.HSNCode,
                CGSTRate = editItem?.CGSTRate ?? 0,
                SGSTRate = editItem?.SGSTRate ?? 0
            },
            Pumps = pumps,
            Products = products,
            Message = TempData["ProductMessage"] as string
        };
    }

    private async Task<TankManagementViewModel> BuildTankViewModelAsync(long? editId, long? pumpId, string? searchTerm, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null)
        {
            return new TankManagementViewModel();
        }

        var ownerId = GetOwnerId();
        var pumps = await apiClient.GetPumpsAsync(token, ownerId, cancellationToken);
        var selectedPumpId = pumpId ?? pumps.FirstOrDefault()?.Id ?? 0;
        var products = await apiClient.GetProductsAsync(token, ownerId, selectedPumpId > 0 ? selectedPumpId : null, cancellationToken);
        if (products.Count == 0)
        {
            products = await apiClient.GetProductsAsync(token, ownerId, null, cancellationToken);
        }

        var tanksResponse = selectedPumpId > 0
            ? await apiClient.GetTanksAsync(token, ownerId, selectedPumpId, searchTerm, 1, 50, cancellationToken)
            : new ApiPagedResponse<ApiTankDto>(Array.Empty<ApiTankDto>(), 0, 1, 50);

        var editItem = editId is null ? null : tanksResponse.Items.FirstOrDefault(x => x.Id == editId.Value);

        return new TankManagementViewModel
        {
            Form = new TankForm
            {
                Id = editItem?.Id ?? 0,
                OwnerId = ownerId,
                PumpId = editItem?.PumpId ?? selectedPumpId,
                Name = editItem?.Name ?? string.Empty,
                ProductId = editItem?.ProductId ?? products.FirstOrDefault()?.Id ?? 0,
                Capacity = editItem?.Capacity ?? 0,
                SafeFillLevel = editItem?.SafeFillLevel ?? 0,
                CurrentStock = editItem?.CurrentStock ?? 0,
                IsActive = editItem?.IsActive ?? true
            },
            Pumps = pumps,
            Products = products,
            Tanks = tanksResponse.Items,
            SearchTerm = searchTerm,
            Message = TempData["TankMessage"] as string
        };
    }

    private async Task<PartyManagementViewModel> BuildPartyViewModelAsync(long? editId, long? pumpId, string? searchTerm, int? pageNumber, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null)
        {
            return new PartyManagementViewModel();
        }

        var ownerId = GetOwnerId();
        var pumps = await apiClient.GetPumpsAsync(token, ownerId, cancellationToken);
        var selectedPumpId = pumpId ?? pumps.FirstOrDefault()?.Id ?? 0;

        // Pehle yahan hamesha "page 1, 50 party" maangi jaati thi aur page badalne ka koi
        // button nahi tha — 51vi party list me kabhi dikhti hi nahi thi.
        const int pageSize = 25;
        var pNum = Math.Max(1, pageNumber ?? 1);

        var partiesResponse = selectedPumpId > 0
            ? await apiClient.GetPartiesAsync(token, ownerId, selectedPumpId, searchTerm, pNum, pageSize, cancellationToken)
            : new ApiPagedResponse<ApiPartyDto>(Array.Empty<ApiPartyDto>(), 0, 1, pageSize);

        // Aakhri page ki aakhri party hatane ke baad wahi page khaali aata — ek peeche chale jao.
        if (partiesResponse.Items.Count == 0 && partiesResponse.TotalCount > 0 && pNum > 1)
        {
            pNum = Math.Max(1, (int)Math.Ceiling(partiesResponse.TotalCount / (double)pageSize));
            partiesResponse = await apiClient.GetPartiesAsync(token, ownerId, selectedPumpId, searchTerm, pNum, pageSize, cancellationToken);
        }

        ApiPartyDto? editItem = null;
        if (editId is not null && selectedPumpId > 0)
        {
            editItem = await apiClient.GetPartyByIdAsync(token, ownerId, selectedPumpId, editId.Value, cancellationToken)
                ?? partiesResponse.Items.FirstOrDefault(x => x.Id == editId.Value);
        }

        return new PartyManagementViewModel
        {
            Form = new PartyForm
            {
                Id = editItem?.Id ?? 0,
                OwnerId = ownerId,
                PumpId = editItem?.PumpId ?? selectedPumpId,
                PartyName = editItem?.PartyName ?? string.Empty,
                PartyType = editItem?.PartyType ?? "Fleet",
                Address = editItem?.Address ?? string.Empty,
                Mobile = editItem?.Mobile ?? string.Empty,
                Email = editItem?.Email ?? string.Empty,
                GSTIN = editItem?.GSTIN ?? string.Empty,
                CreditLimit = editItem?.CreditLimit ?? 0,
                CurrentBalance = editItem?.CurrentBalance ?? 0,
                OriginalBalance = editItem?.CurrentBalance ?? 0,
                IsActive = editItem?.IsActive ?? true
            },
            Pumps = pumps,
            Parties = partiesResponse.Items,
            PageNumber = pNum,
            PageSize = pageSize,
            TotalCount = partiesResponse.TotalCount,
            SearchTerm = searchTerm,
            Message = TempData["PartyMessage"] as string
        };
    }

    private async Task<TankStockViewModel> BuildTankStockViewModelAsync(long? pumpId, long? tankId, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null)
        {
            return new TankStockViewModel();
        }

        var ownerId = GetOwnerId();
        var pumps = await apiClient.GetPumpsAsync(token, ownerId, cancellationToken);
        var selectedPumpId = pumpId ?? pumps.FirstOrDefault()?.Id ?? 0;
        var tanks = selectedPumpId > 0
            ? (await apiClient.GetTanksAsync(token, ownerId, selectedPumpId, null, 1, 100, cancellationToken)).Items
            : Array.Empty<ApiTankDto>();
        var selectedTankId = tankId ?? tanks.FirstOrDefault()?.Id ?? 0;
        var txns = selectedPumpId > 0
            ? await apiClient.GetTankTransactionsAsync(token, ownerId, selectedPumpId, selectedTankId > 0 ? selectedTankId : null, cancellationToken)
            : Array.Empty<ApiTankTransactionDto>();

        return new TankStockViewModel
        {
            Form = new TankStockForm
            {
                OwnerId = ownerId,
                PumpId = selectedPumpId,
                TankId = selectedTankId,
                TxnType = "PURCHASE"
            },
            Pumps = pumps,
            Tanks = tanks,
            Transactions = txns,
            Message = TempData["TankStockMessage"] as string
        };
    }

    private async Task<PartyLedgerViewModel> BuildPartyLedgerViewModelAsync(long? pumpId, long? partyId, string? searchTerm, int? pageNumber, int? pageSize, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null)
        {
            return new PartyLedgerViewModel();
        }

        var pNum = pageNumber ?? 1;
        // Khaate me 20: har line ke saath chalta hua baki hai, thoda zyada ek saath dikhe to
        // hisaab milana aasan. (50 par pager kabhi aata hi nahi tha.)
        var pSize = pageSize is >= 5 and <= 200 ? pageSize.Value : 20;

        var ownerId = GetOwnerId();
        var pumps = await apiClient.GetPumpsAsync(token, ownerId, cancellationToken);
        var selectedPumpId = pumpId ?? pumps.FirstOrDefault()?.Id ?? 0;
        var parties = selectedPumpId > 0
            ? await apiClient.GetAllPartiesAsync(token, ownerId, selectedPumpId, cancellationToken)
            : Array.Empty<ApiPartyDto>();
        var selectedPartyId = partyId ?? parties.FirstOrDefault()?.Id ?? 0;

        // Chuni hui party ka khaata purane baki aur chalte hue baki ke saath. Saadi list
        // me purana baki dikhta hi nahi tha (wo khaate ki line nahi hai), isliye "25 hazaar
        // jama kiya phir bhi 41 hazaar baki kyun" ka jawab page par milta hi nahi tha.
        var statement = selectedPumpId > 0 && selectedPartyId > 0
            ? await apiClient.GetPartyStatementAsync(token, selectedPumpId, selectedPartyId, searchTerm, pNum, pSize, cancellationToken)
            : null;

        // Statement na mile (purani API) tabhi purani list — dono mangwana bekaar hai.
        var ledger = statement is null && selectedPumpId > 0
            ? await apiClient.GetPagedPartyLedgerAsync(token, ownerId, selectedPumpId, selectedPartyId > 0 ? selectedPartyId : null, searchTerm, pNum, pSize, cancellationToken)
            : new ApiPagedResponse<ApiPartyLedgerEntryDto>(Array.Empty<ApiPartyLedgerEntryDto>(), 0, pNum, pSize);

        return new PartyLedgerViewModel
        {
            Form = new PartyLedgerForm
            {
                OwnerId = ownerId,
                PumpId = selectedPumpId,
                PartyId = selectedPartyId,
                // Pehle "CREDIT" (= Adjustment, baki ghatao) pehle se chuna aata tha, jabki
                // is form ka 90% kaam jama (Receipt) ka hai. Live par 14 Oct ko ek party kih ki
                // 5,000 isi wajah se Adjustment me gayi. Baki par asar dono ka same hai, par
                // reports me "jama" sirf RECEIPT ko ginti hain.
                EntryType = "RECEIPT"
            },
            Pumps = pumps,
            Parties = parties,
            LedgerEntries = ledger,
            Statement = statement,
            SearchTerm = searchTerm,
            Message = TempData["PartyLedgerMessage"] as string
        };
    }

    private async Task<PurchaseManagementViewModel> BuildPurchaseViewModelAsync(long? pumpId, DateTime? fromDate, DateTime? toDate, string? searchTerm, int pageNumber, int pageSize, long? editId, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null)
        {
            return new PurchaseManagementViewModel();
        }

        var ownerId = GetOwnerId();
        var pumps = await apiClient.GetPumpsAsync(token, ownerId, cancellationToken);
        var selectedPumpId = pumpId ?? pumps.FirstOrDefault()?.Id ?? 0;
        var allVendors = selectedPumpId > 0
            ? await apiClient.GetVendorsAsync(token, ownerId, selectedPumpId, cancellationToken)
            : Array.Empty<ApiVendorDto>();
        var vendors = allVendors.Where(x => x.IsActive).ToList();
        var products = await apiClient.GetProductsAsync(token, ownerId, selectedPumpId > 0 ? selectedPumpId : null, cancellationToken);
        var tanks = selectedPumpId > 0
            ? (await apiClient.GetTanksAsync(token, ownerId, selectedPumpId, null, 1, 100, cancellationToken)).Items
            : Array.Empty<ApiTankDto>();
        var purchases = selectedPumpId > 0
            ? await apiClient.GetPagedPurchasesAsync(token, ownerId, selectedPumpId, fromDate, toDate, searchTerm, pageNumber, pageSize, cancellationToken)
            : null;

        var firstProduct = products.FirstOrDefault();
        var firstVendor = vendors.FirstOrDefault();

        var model = new PurchaseManagementViewModel
        {
            Form = new PurchaseForm
            {
                OwnerId = ownerId,
                PumpId = selectedPumpId,
                VendorId = firstVendor?.Id ?? 0,
                InvoiceNo = $"INV-{DateTime.Now:yyyyMMddHHmm}",
                InvoiceDate = DateOnly.FromDateTime(DateTime.Today),
                Items = new List<PurchaseLineForm>
                {
                    new()
                    {
                        ProductId = firstProduct?.Id ?? 0,
                        TankId = tanks.FirstOrDefault(x => x.ProductId == (firstProduct?.Id ?? 0))?.Id
                        // Matra aur rakam jaanbujh kar KHAALI - bill dekh kar bharni hain.
                    }
                }
            },
            Pumps = pumps,
            Vendors = vendors,
            Products = products,
            Tanks = tanks,
            Purchases = purchases,
            FromDate = fromDate,
            ToDate = toDate,
            SearchTerm = searchTerm,
            PageNumber = pageNumber,
            PageSize = pageSize,
            Message = TempData["PurchaseMessage"] as string
        };

        if (editId.HasValue && editId.Value > 0)
        {
            var purchase = await apiClient.GetPurchaseByIdAsync(token, editId.Value, ownerId, cancellationToken);
            if (purchase is not null)
            {
                model.Form = new PurchaseForm
                {
                    Id = purchase.Id,
                    OwnerId = purchase.OwnerId,
                    PumpId = purchase.PumpId,
                    VendorId = purchase.VendorId,
                    InvoiceNo = purchase.InvoiceNo,
                    InvoiceDate = purchase.InvoiceDate,
                    VehicleNo = purchase.VehicleNo,
                    DriverName = purchase.DriverName,
                    Notes = purchase.Notes,
                    Items = purchase.Items.Select(x => new PurchaseLineForm
                    {
                        ProductId = x.ProductId,
                        TankId = x.TankId,
                        Quantity = x.Quantity,
                        Rate = x.Rate,
                        // Purani entry (ya purani API) me rakam alag nahi hoti - tab Quantity x Rate.
                        Amount = x.Amount > 0
                            ? x.Amount
                            : decimal.Round(x.Quantity * x.Rate, 2, MidpointRounding.AwayFromZero)
                    }).ToList()
                };

                // Ensure the purchase's vendor is in model.Vendors list
                if (!model.Vendors.Any(x => x.Id == purchase.VendorId))
                {
                    var vendor = allVendors.FirstOrDefault(x => x.Id == purchase.VendorId);
                    if (vendor != null)
                    {
                        model.Vendors = model.Vendors.Concat(new[] { vendor }).ToList();
                    }
                }
            }
        }

        return model;
    }

    private async Task<StockReconciliationViewModel> BuildStockReconciliationViewModelAsync(long? pumpId, long? tankId, DateTime? fromDate, DateTime? toDate, string? searchTerm, int pageNumber, int pageSize, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null)
        {
            return new StockReconciliationViewModel();
        }

        var ownerId = GetOwnerId();
        var pumps = await apiClient.GetPumpsAsync(token, ownerId, cancellationToken);
        var selectedPumpId = pumpId ?? pumps.FirstOrDefault()?.Id ?? 0;
        var tanks = selectedPumpId > 0
            ? (await apiClient.GetTanksAsync(token, ownerId, selectedPumpId, null, 1, 100, cancellationToken)).Items
            : Array.Empty<ApiTankDto>();
        var selectedTankId = tankId ?? tanks.FirstOrDefault()?.Id ?? 0;
        var selectedTank = tanks.FirstOrDefault(x => x.Id == selectedTankId);
        var entries = selectedPumpId > 0
            ? await apiClient.GetPagedStockReconciliationsAsync(token, ownerId, selectedPumpId, selectedTankId > 0 ? selectedTankId : null, fromDate, toDate, searchTerm, pageNumber, pageSize, cancellationToken)
            : null;

        var bookStock = selectedTank != null
            ? (fromDate.HasValue
                ? await apiClient.GetTankStockAsOfDateAsync(token, selectedTank.Id, ownerId, DateOnly.FromDateTime(fromDate.Value), cancellationToken)
                : selectedTank.CurrentStock)
            : 0;

        return new StockReconciliationViewModel
        {
            Form = new StockReconciliationForm
            {
                OwnerId = ownerId,
                PumpId = selectedPumpId,
                TankId = selectedTankId,
                ReconciliationDate = fromDate.HasValue ? DateOnly.FromDateTime(fromDate.Value) : DateOnly.FromDateTime(DateTime.Today),
                BookStock = bookStock,
                PhysicalStock = bookStock
            },
            Pumps = pumps,
            Tanks = tanks,
            Entries = entries,
            FromDate = fromDate,
            ToDate = toDate,
            SearchTerm = searchTerm,
            PageNumber = pageNumber,
            PageSize = pageSize,
            Message = TempData["StockReconcileMessage"] as string
        };
    }

    [HttpGet]
    public async Task<IActionResult> GetTankStockAsOfDate(long tankId, string date, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null) return Unauthorized();

        var ownerId = GetOwnerId();
        if (!DateOnly.TryParse(date, out var parsedDate))
        {
            parsedDate = DateOnly.FromDateTime(DateTime.Today);
        }

        var stock = await apiClient.GetTankStockAsOfDateAsync(token, tankId, ownerId, parsedDate, cancellationToken);
        return Json(new { stock });
    }

    private async Task<CashbookViewModel> BuildCashbookViewModelAsync(long? pumpId, DateTime? fromDate, DateTime? toDate, string? searchTerm, int pageNumber, int pageSize, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null)
        {
            return new CashbookViewModel();
        }

        var ownerId = GetOwnerId();
        var pumps = await apiClient.GetPumpsAsync(token, ownerId, cancellationToken);
        var selectedPumpId = pumpId ?? pumps.FirstOrDefault()?.Id ?? 0;
        var txns = selectedPumpId > 0
            ? await apiClient.GetPagedCashTransactionsAsync(token, ownerId, selectedPumpId, fromDate, toDate, searchTerm, pageNumber, pageSize, cancellationToken)
            : null;

        // Khuli shift — taaki cash entry usi shift ke hisaab me jude.
        var allShifts = selectedPumpId > 0
            ? await apiClient.GetShiftsAsync(
                token, ownerId, selectedPumpId,
                // Yahan sirf KHULI shift chahiye (dropdown ke liye), aur khuli shift
                // hamesha nayi hoti hai — 15 din kaafi hai.
                DateOnly.FromDateTime(DateTime.Today.AddDays(-15)),
                DateOnly.FromDateTime(DateTime.Today), 200, cancellationToken)
            : Array.Empty<ApiShiftDto>();
        var openShifts = allShifts.Where(x => string.Equals(x.Status, "OPEN", StringComparison.OrdinalIgnoreCase)).ToList();

        return new CashbookViewModel
        {
            Form = new CashbookForm
            {
                OwnerId = ownerId,
                PumpId = selectedPumpId,
                ShiftId = openShifts.FirstOrDefault()?.Id,
                TxnType = "IN"
            },
            Pumps = pumps,
            OpenShifts = openShifts,
            LinkableShifts = BuildLinkableShifts(allShifts, selectedPumpId),
            Transactions = txns,
            FromDate = fromDate,
            ToDate = toDate,
            SearchTerm = searchTerm,
            PageNumber = pageNumber,
            PageSize = pageSize,
            Message = TempData["CashbookMessage"] as string
        };
    }

    private async Task<ExpenseViewModel> BuildExpenseViewModelAsync(long? pumpId, DateTime? fromDate, DateTime? toDate, string? searchTerm, int pageNumber, int pageSize, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null)
        {
            return new ExpenseViewModel();
        }

        var ownerId = GetOwnerId();
        var pumps = await apiClient.GetPumpsAsync(token, ownerId, cancellationToken);
        var selectedPumpId = pumpId ?? pumps.FirstOrDefault()?.Id ?? 0;
        var heads = selectedPumpId > 0
            ? await apiClient.GetExpenseHeadsAsync(token, ownerId, selectedPumpId, cancellationToken)
            : Array.Empty<ApiExpenseHeadDto>();
        var expenses = selectedPumpId > 0
            ? await apiClient.GetPagedExpensesAsync(token, ownerId, selectedPumpId, fromDate, toDate, searchTerm, pageNumber, pageSize, cancellationToken)
            : null;

        // Khuli shift — cash expense usi shift ke expected cash me ghata jaye.
        var allShifts = selectedPumpId > 0
            ? await apiClient.GetShiftsAsync(
                token, ownerId, selectedPumpId,
                // Yahan sirf KHULI shift chahiye (dropdown ke liye), aur khuli shift
                // hamesha nayi hoti hai — 15 din kaafi hai.
                DateOnly.FromDateTime(DateTime.Today.AddDays(-15)),
                DateOnly.FromDateTime(DateTime.Today), 200, cancellationToken)
            : Array.Empty<ApiShiftDto>();
        var openShifts = allShifts.Where(x => string.Equals(x.Status, "OPEN", StringComparison.OrdinalIgnoreCase)).ToList();

        return new ExpenseViewModel
        {
            Form = new ExpenseForm
            {
                OwnerId = ownerId,
                PumpId = selectedPumpId,
                ShiftId = openShifts.FirstOrDefault()?.Id,
                ExpenseHeadId = heads.FirstOrDefault()?.Id ?? 0,
                PaymentMode = "Cash"
            },
            Pumps = pumps,
            Heads = heads,
            OpenShifts = openShifts,
            LinkableShifts = BuildLinkableShifts(allShifts, selectedPumpId),
            Expenses = expenses,
            Message = TempData["ExpenseMessage"] as string,
            SearchTerm = searchTerm,
            FromDate = fromDate,
            ToDate = toDate,
            PageNumber = pageNumber,
            PageSize = pageSize
        };
    }

    private async Task<DipTestingViewModel> BuildDipTestingViewModelAsync(long? pumpId, DateTime? fromDate, DateTime? toDate, int pageNumber, int pageSize, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null)
        {
            return new DipTestingViewModel();
        }

        var ownerId = GetOwnerId();
        var pumps = await apiClient.GetPumpsAsync(token, ownerId, cancellationToken);
        var selectedPumpId = pumpId ?? pumps.FirstOrDefault()?.Id ?? 0;
        var tankPage = selectedPumpId > 0
            ? await apiClient.GetTanksAsync(token, ownerId, selectedPumpId, null, 1, 200, cancellationToken)
            : new ApiPagedResponse<ApiTankDto>(Array.Empty<ApiTankDto>(), 0, 1, 200);
        var tanks = tankPage.Items;
        var shifts = selectedPumpId > 0
            ? await apiClient.GetShiftsAsync(
                token, ownerId, selectedPumpId,
                // Yahan sirf KHULI shift chahiye (dropdown ke liye), aur khuli shift
                // hamesha nayi hoti hai — 15 din kaafi hai.
                DateOnly.FromDateTime(DateTime.Today.AddDays(-15)),
                DateOnly.FromDateTime(DateTime.Today), 200, cancellationToken)
            : Array.Empty<ApiShiftDto>();
        var openShifts = shifts
            .Where(x => string.Equals(x.Status, "OPEN", StringComparison.OrdinalIgnoreCase))
            .OrderByDescending(x => x.Id)
            .ToList();

        var dipReadings = selectedPumpId > 0
            ? await apiClient.GetPagedDipReadingsAsync(token, ownerId, selectedPumpId, fromDate, toDate, pageNumber, pageSize, cancellationToken)
            : null;
        var testingLosses = selectedPumpId > 0
            ? await apiClient.GetPagedTestingLossesAsync(token, ownerId, selectedPumpId, fromDate, toDate, pageNumber, pageSize, cancellationToken)
            : null;
        var defaultTank = tanks.FirstOrDefault();
        var defaultTankId = defaultTank?.Id ?? 0;
        var defaultTankStock = defaultTank?.CurrentStock ?? 0;
        var defaultShiftId = openShifts.FirstOrDefault()?.Id;

        return new DipTestingViewModel
        {
            DipReadingForm = new DipReadingForm
            {
                OwnerId = ownerId,
                PumpId = selectedPumpId,
                TankId = defaultTankId,
                ReadingDate = DateTime.Now,
                ShiftId = defaultShiftId,
                DipCm = 0,
                ExpectedStock = defaultTankStock,   // ✅ FIX: Tank ka actual book stock auto-fill
                ActualStock = 0
            },

            TestingLossForm = new TestingLossForm
            {
                OwnerId = ownerId,
                PumpId = selectedPumpId,
                TankId = defaultTankId,
                LossDate = DateTime.Now,
                ShiftId = defaultShiftId,
                LossType = "Testing",
                Quantity = 0
            },
            Pumps = pumps,
            Tanks = tanks,
            OpenShifts = openShifts,
            LinkableShifts = BuildLinkableShifts(shifts, selectedPumpId),
            DipReadings = dipReadings,
            TestingLosses = testingLosses,
            FromDate = fromDate,
            ToDate = toDate,
            PageNumber = pageNumber,
            PageSize = pageSize,
            Message = TempData["DipTestingMessage"] as string
        };
    }

    private async Task<DayBookViewModel> BuildDayBookViewModelAsync(long? pumpId, DateOnly? dateFrom, DateOnly? dateTo, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null)
        {
            return new DayBookViewModel();
        }

        var ownerId = GetOwnerId();
        var pumps = await apiClient.GetPumpsAsync(token, ownerId, cancellationToken);
        var selectedPumpId = pumpId ?? pumps.FirstOrDefault()?.Id ?? 0;
        var from = dateFrom ?? DateOnly.FromDateTime(DateTime.Today.AddDays(-7));
        var to = dateTo ?? DateOnly.FromDateTime(DateTime.Today);
        var entries = selectedPumpId > 0
            ? await apiClient.GetDayBookAsync(token, ownerId, selectedPumpId, from, to, cancellationToken)
            : Array.Empty<ApiDayBookEntryDto>();
        var shifts = selectedPumpId > 0
            ? await apiClient.GetPagedShiftsAsync(
                token,
                ownerId,
                selectedPumpId,
                from.ToDateTime(TimeOnly.MinValue),
                to.ToDateTime(TimeOnly.MaxValue),
                searchTerm: null,
                pageNumber: 1,
                pageSize: 500,
                cancellationToken)
            : null;
        var shiftRows = shifts?.Items.Select(x => new DayBookShiftSummaryRow
        {
            ShiftId = x.Id,
            ShiftDate = x.ShiftDate,
            ShiftCode = x.ShiftCode,
            OperatorName = x.OperatorName ?? "-",
            OpeningCash = x.OpeningCash,
            ClosingCash = x.ClosingCash,
            SoldQty = x.TotalSoldQty,
            SoldAmount = x.TotalSoldAmount
        }).ToList() ?? new List<DayBookShiftSummaryRow>();

        return new DayBookViewModel
        {
            Filter = new DayBookFilter
            {
                OwnerId = ownerId,
                PumpId = selectedPumpId,
                DateFrom = from,
                DateTo = to
            },
            Pumps = pumps,
            Entries = entries,
            ShiftSummaries = shiftRows
        };
    }

    private async Task<ReportsHomeViewModel> BuildReportsHomeViewModelAsync(CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null)
        {
            return new ReportsHomeViewModel();
        }

        var ownerId = GetOwnerId();
        var pumps = await apiClient.GetPumpsAsync(token, ownerId, cancellationToken);
        return new ReportsHomeViewModel
        {
            Pumps = pumps,
            PumpId = pumps.FirstOrDefault()?.Id ?? 0
        };
    }

    private async Task<OutstandingReportViewModel> BuildOutstandingReportViewModelAsync(long? pumpId, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null)
        {
            return new OutstandingReportViewModel();
        }

        var ownerId = GetOwnerId();
        var pumps = await apiClient.GetPumpsAsync(token, ownerId, cancellationToken);
        var selectedPumpId = pumpId ?? pumps.FirstOrDefault()?.Id ?? 0;
        var items = selectedPumpId > 0
            ? await apiClient.GetOutstandingAsync(token, ownerId, selectedPumpId, cancellationToken)
            : Array.Empty<ApiOutstandingPartyDto>();

        return new OutstandingReportViewModel
        {
            OwnerId = ownerId,
            PumpId = selectedPumpId,
            Pumps = pumps,
            Items = items
        };
    }

    private async Task<PumpComparisonReportViewModel> BuildPumpComparisonReportViewModelAsync(DateOnly? dateFrom, DateOnly? dateTo, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null)
        {
            return new PumpComparisonReportViewModel();
        }

        var ownerId = GetOwnerId();
        var from = dateFrom ?? DateOnly.FromDateTime(DateTime.Today.AddDays(-7));
        var to = dateTo ?? DateOnly.FromDateTime(DateTime.Today);
        var items = await apiClient.GetPumpComparisonAsync(token, ownerId, from, to, cancellationToken);

        return new PumpComparisonReportViewModel
        {
            OwnerId = ownerId,
            DateFrom = from,
            DateTo = to,
            Items = items
        };
    }

    private async Task<DailyStockRegisterViewModel> BuildDailyStockRegisterViewModelAsync(long? pumpId, long? productId, int? month, int? year, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null) return new DailyStockRegisterViewModel();

        var ownerId = GetOwnerId();
        var pumps = await apiClient.GetPumpsAsync(token, ownerId, cancellationToken);
        var selectedPumpId = pumpId ?? pumps.FirstOrDefault()?.Id ?? 0;

        var products = await apiClient.GetProductsAsync(token, ownerId, selectedPumpId, cancellationToken);
        var selectedProductId = productId ?? products.FirstOrDefault(p => p.Name.Contains("HSD") || p.Name.Contains("Diesel"))?.Id ?? products.FirstOrDefault()?.Id ?? 0;

        var selectedMonth = month ?? DateTime.Today.Month;
        var selectedYear = year ?? DateTime.Today.Year;

        var items = (selectedPumpId > 0 && selectedProductId > 0)
            ? await apiClient.GetDailyStockRegisterAsync(token, selectedPumpId, selectedProductId, selectedMonth, selectedYear, cancellationToken)
            : Array.Empty<ApiDailyStockRegisterDto>();

        return new DailyStockRegisterViewModel
        {
            PumpId = selectedPumpId,
            ProductId = selectedProductId,
            Month = selectedMonth,
            Year = selectedYear,
            Pumps = pumps,
            Products = products,
            Items = items
        };
    }

    private async Task<SalePurchaseRegisterViewModel> BuildSalePurchaseRegisterViewModelAsync(long? pumpId, long? productId, int? month, int? year, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null) return new SalePurchaseRegisterViewModel();

        var ownerId = GetOwnerId();
        var pumps = await apiClient.GetPumpsAsync(token, ownerId, cancellationToken);
        var selectedPumpId = pumpId ?? pumps.FirstOrDefault()?.Id ?? 0;

        var products = await apiClient.GetProductsAsync(token, ownerId, selectedPumpId, cancellationToken);
        var selectedProductId = productId
            ?? products.FirstOrDefault(p => p.Name.Contains("HSD") || p.Name.Contains("Diesel"))?.Id
            ?? products.FirstOrDefault()?.Id ?? 0;

        var selectedMonth = month ?? DateTime.Today.Month;
        var selectedYear = year ?? DateTime.Today.Year;

        var items = (selectedPumpId > 0 && selectedProductId > 0)
            ? await apiClient.GetSalePurchaseRegisterAsync(token, selectedPumpId, selectedProductId, selectedMonth, selectedYear, cancellationToken)
            : Array.Empty<ApiMonthlySaleRegisterRow>();

        return new SalePurchaseRegisterViewModel
        {
            PumpId = selectedPumpId,
            ProductId = selectedProductId,
            Month = selectedMonth,
            Year = selectedYear,
            Pumps = pumps,
            Products = products,
            Items = items
        };
    }

    private async Task<FleetContractsViewModel> BuildFleetContractsViewModelAsync(long? pumpId, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null)
        {
            return new FleetContractsViewModel();
        }

        var ownerId = GetOwnerId();
        var pumps = await apiClient.GetPumpsAsync(token, ownerId, cancellationToken);
        var selectedPumpId = pumpId ?? pumps.FirstOrDefault()?.Id ?? 0;
        var parties = selectedPumpId > 0
            ? await apiClient.GetAllPartiesAsync(token, ownerId, selectedPumpId, cancellationToken)
            : Array.Empty<ApiPartyDto>();
        var products = await apiClient.GetProductsAsync(token, ownerId, selectedPumpId > 0 ? selectedPumpId : null, cancellationToken);
        var contracts = selectedPumpId > 0
            ? await apiClient.GetFleetContractsAsync(token, ownerId, selectedPumpId, cancellationToken)
            : Array.Empty<ApiFleetContractDto>();

        return new FleetContractsViewModel
        {
            Form = new FleetContractForm
            {
                OwnerId = ownerId,
                PumpId = selectedPumpId,
                PartyId = parties.FirstOrDefault()?.Id ?? 0,
                ProductId = products.FirstOrDefault()?.Id ?? 0,
                ContractRate = products.FirstOrDefault()?.CurrentRate ?? 0,
                ValidFrom = DateOnly.FromDateTime(DateTime.Today),
                IsActive = true
            },
            Pumps = pumps,
            Parties = parties,
            Products = products,
            Contracts = contracts,
            Message = TempData["FleetContractMessage"] as string
        };
    }

    private async Task<CouponBooksViewModel> BuildCouponBooksViewModelAsync(long? pumpId, long? couponBookId, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null)
        {
            return new CouponBooksViewModel();
        }

        var ownerId = GetOwnerId();
        var pumps = await apiClient.GetPumpsAsync(token, ownerId, cancellationToken);
        var selectedPumpId = pumpId ?? pumps.FirstOrDefault()?.Id ?? 0;
        var parties = selectedPumpId > 0
            ? await apiClient.GetAllPartiesAsync(token, ownerId, selectedPumpId, cancellationToken)
            : Array.Empty<ApiPartyDto>();
        var books = selectedPumpId > 0
            ? await apiClient.GetCouponBooksAsync(token, ownerId, selectedPumpId, cancellationToken)
            : Array.Empty<ApiCouponBookDto>();
        var selectedBookId = couponBookId ?? books.FirstOrDefault()?.Id ?? 0;
        var txns = selectedPumpId > 0
            ? await apiClient.GetCouponTransactionsAsync(token, ownerId, selectedPumpId, selectedBookId > 0 ? selectedBookId : null, cancellationToken)
            : Array.Empty<ApiCouponTransactionDto>();
        var selectedBook = books.FirstOrDefault(x => x.Id == selectedBookId);

        return new CouponBooksViewModel
        {
            Form = new CouponBookForm
            {
                OwnerId = ownerId,
                PumpId = selectedPumpId,
                BookCode = $"CPN-{DateTime.Now:MMddHHmm}",
                Denomination = 500,
                TotalCoupons = 100,
                IssuedToPartyId = parties.FirstOrDefault()?.Id,
                StartSerial = 1,
                EndSerial = 100,
                IsActive = true
            },
            TxnForm = new CouponTransactionForm
            {
                OwnerId = ownerId,
                PumpId = selectedPumpId,
                CouponBookId = selectedBookId,
                PartyId = selectedBook?.IssuedToPartyId,
                CouponSerialNo = selectedBook?.StartSerial ?? 1,
                Amount = selectedBook?.Denomination ?? 0
            },
            Pumps = pumps,
            Parties = parties,
            Books = books,
            Transactions = txns,
            Message = TempData["CouponBookMessage"] as string
        };
    }


    /// <summary>
    /// Jin shift se koi entry (cash, kharcha, dip, bill) jodi ja sakti hai.
    ///
    /// Khuli shift sabse upar, uske baad haal me band hui shift nayi se purani.
    /// Pehle sirf khuli shift dikhti thi, isliye purane din ki entry us din ki
    /// shift se jud hi nahi paati thi — ShiftId NULL chala jaata tha aur wo
    /// entry us shift ke cash milan me kabhi nahi aati thi.
    /// </summary>
    private static List<ApiShiftDto> BuildLinkableShifts(IEnumerable<ApiShiftDto> allShifts, long pumpId)
    {
        // 60 din se purani shift dikhane ka koi matlab nahi — list bhar jaati hai.
        var cutoff = DateOnly.FromDateTime(DateTime.Today.AddDays(-60));

        return allShifts
            .Where(x => pumpId <= 0 || x.PumpId == pumpId)
            .Where(x => string.Equals(x.Status, "OPEN", StringComparison.OrdinalIgnoreCase)
                        || x.ShiftDate >= cutoff)
            .OrderByDescending(x => string.Equals(x.Status, "OPEN", StringComparison.OrdinalIgnoreCase))
            .ThenByDescending(x => x.ShiftDate)
            .ThenByDescending(x => x.Id)
            .Take(60)
            .ToList();
    }

    private async Task<ShiftManagementViewModel> BuildShiftViewModelAsync(long? pumpId, DateTime? fromDate, DateTime? toDate, string? searchTerm, int pageNumber, int pageSize, CancellationToken cancellationToken, DateOnly? shiftDate = null)
    {
        var token = GetToken();
        if (token is null)
        {
            return new ShiftManagementViewModel();
        }

        var ownerId = GetOwnerId();
        var shifts = await apiClient.GetPagedShiftsAsync(token, ownerId, pumpId, fromDate, toDate, searchTerm, pageNumber, pageSize, cancellationToken);

        // Page 3 par khade ho aur phir aisa filter lagao jiske sirf 6 nateeje hain, to
        // pageNumber 3 hi reh jaata tha — screen khaali dikhti thi aur "Showing 21-6 of 6"
        // jaisa ulta text aata tha. Aise me pehle page par le aate hain.
        if (shifts is not null && shifts.Items.Count == 0 && shifts.TotalCount > 0 && pageNumber > 1)
        {
            pageNumber = 1;
            shifts = await apiClient.GetPagedShiftsAsync(token, ownerId, pumpId, fromDate, toDate, searchTerm, pageNumber, pageSize, cancellationToken);
        }

        var pumps = await apiClient.GetPumpsAsync(token, ownerId, cancellationToken);
        var selectedPumpId = pumpId ?? pumps.FirstOrDefault()?.Id ?? 1;
        var nozzles = selectedPumpId > 0
            ? await apiClient.GetNozzlesAsync(token, ownerId, selectedPumpId, cancellationToken)
            : Array.Empty<ApiNozzleDto>();
        // Kis din ki shift khulne ja rahi hai — usi din (ya usse pehle) ki
        // aakhri band shift se opening reading aur cash aana chahiye.
        //
        // Pehle hamesha "sabse baad me band hui" shift se aata tha. Kram se din
        // bharo to wo theek tha, par beech ka chhoota din baad me bharne par
        // aage wale din ki reading utha laata tha aur hisaab chupchap bigad
        // jaata tha.
        var forDate = shiftDate ?? DateOnly.FromDateTime(DateTime.Today);

        var lastReadings = selectedPumpId > 0
            ? await apiClient.GetLastNozzleReadingsAsync(token, selectedPumpId, forDate, cancellationToken)
            : Array.Empty<ApiShiftNozzleReadingDto>();
        // Meter ki tooti hui kadi (Section R2) — page ke upar chetavni ke liye.
        // Shift kholte waqt bhi rok lagti hai, par purani tareekh ki entry ya
        // "meter badla hai" tick karke aage badhne par kadi tab bhi tooti reh
        // sakti hai. Wo yahan pakad me aa jaati hai.
        var meterChainGaps = await apiClient.GetMeterChainGapsAsync(
            token, selectedPumpId > 0 ? selectedPumpId : null, 90, cancellationToken);
        var allEmployees = selectedPumpId > 0
            ? await apiClient.GetEmployeesAsync(token, ownerId, selectedPumpId, cancellationToken)
            : Array.Empty<ApiEmployeeDto>();
        // In-charge aur nozzle attendant — ab dono ek hi list se aate hain.
        // Pehle in-charge me `x.UserId is > 0` ka filter tha (kyunki wo Users se
        // judta tha), isliye bina-login wale log in-charge ban hi nahi sakte the.
        // Section K ke baad in-charge bhi Employees se judta hai, so filter gaya.
        var allActiveEmployees = allEmployees
            .Where(x => x.IsActive)
            .OrderBy(x => x.FullName)
            .ToList();
        var operators = allActiveEmployees;

        // Pehle se kisi ko mat chuno — "-- Not assigned --" hi theek default hai,
        // warna list ka pehla aadmi chupchaap har shift ka zimmedar ban jaata tha.
        const long defaultOperatorId = 0;

        // Auto-suggest shift code: check today's shifts for this pump
        var todayShifts = shifts?.Items
            .Where(x => x.PumpId == selectedPumpId && x.ShiftDate == DateOnly.FromDateTime(DateTime.Today))
            .Select(x => x.ShiftCode?.Trim().ToUpperInvariant())
            .Where(x => !string.IsNullOrEmpty(x))
            .ToHashSet() ?? new HashSet<string?>();
        var suggestedCode = "A";
        foreach (var code in new[] { "A", "B", "C", "D", "E" })
        {
            if (!todayShifts.Contains(code)) { suggestedCode = code; break; }
        }

        return new ShiftManagementViewModel
        {
            OpenShift = new OpenShiftForm
            {
                OwnerId = ownerId,
                PumpId = selectedPumpId,
                OperatorEmployeeId = defaultOperatorId,
                ShiftDate = DateOnly.FromDateTime(DateTime.Today),
                ShiftCode = suggestedCode,
                OpeningCash = shifts?.Items?
                    .Where(x => x.PumpId == selectedPumpId && x.Status == "CLOSED" && x.ShiftDate <= forDate)
                    .OrderByDescending(x => x.ShiftDate).ThenByDescending(x => x.Id)
                    .FirstOrDefault()?.ClosingCash ?? 0,
                NozzleReadings = nozzles
                    .Select(x => new ShiftNozzleOpenReadingForm
                    {
                        NozzleId = x.Id,
                        ProductId = x.ProductId,
                        NozzleCode = x.NozzleCode,
                        ProductName = x.ProductName,
                        OpeningReading = lastReadings.FirstOrDefault(r => r.NozzleId == x.Id)?.ClosingReading ?? 0
                    })
                    .ToList()
            },
            CloseShift = new CloseShiftForm
            {
                NozzleReadings = nozzles
                    .Select(x => new ShiftNozzleCloseReadingForm
                    {
                        NozzleId = x.Id,
                        NozzleCode = x.NozzleCode,
                        ProductName = x.ProductName,
                        OpeningReading = 0,
                        Rate = 0,
                        ClosingReading = 0
                    })
                    .ToList()
            },
            Pumps = pumps,
            Nozzles = nozzles,
            Operators = operators,
            AllEmployees = allActiveEmployees,
            Shifts = shifts,
            MeterChainGaps = meterChainGaps,
            Message = TempData["ShiftMessage"] as string,
            SearchTerm = searchTerm,
            FromDate = fromDate,
            ToDate = toDate,
            PageNumber = pageNumber,
            PageSize = pageSize
        };
    }

    private async Task<SalesManagementViewModel> BuildSalesViewModelAsync(long? pumpId, DateTime? fromDate, DateTime? toDate, string? searchTerm, int pageNumber, int pageSize, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null)
        {
            return new SalesManagementViewModel();
        }

        var ownerId = GetOwnerId();
        var pumps = await apiClient.GetPumpsAsync(token, ownerId, cancellationToken);
        var selectedPumpId = pumpId ?? pumps.FirstOrDefault()?.Id ?? 0;
        // Yahan sirf khuli shift chunni hoti hai (sale kis shift me jaayegi),
        // aur khuli shift hamesha nayi hoti hai — 15 din kaafi hai.
        var shifts = await apiClient.GetShiftsAsync(
            token, ownerId, selectedPumpId > 0 ? selectedPumpId : null,
            DateOnly.FromDateTime(DateTime.Today.AddDays(-15)),
            DateOnly.FromDateTime(DateTime.Today), 200, cancellationToken);

        var products = await apiClient.GetProductsAsync(token, ownerId, selectedPumpId > 0 ? selectedPumpId : null, cancellationToken);
        var nozzles = await apiClient.GetNozzlesAsync(token, ownerId, selectedPumpId > 0 ? selectedPumpId : null, cancellationToken);
        var parties = selectedPumpId > 0
            ? await apiClient.GetAllPartiesAsync(token, ownerId, selectedPumpId, cancellationToken)
            : Array.Empty<ApiPartyDto>();
        var sales = await apiClient.GetSalesAsync(token, ownerId, selectedPumpId > 0 ? selectedPumpId : null, fromDate, toDate, searchTerm, pageNumber, pageSize, cancellationToken);

        var openShifts = shifts
            .Where(x => string.Equals(x.Status, "OPEN", StringComparison.OrdinalIgnoreCase))
            .OrderByDescending(x => x.Id)
            .ToList();

        var pumpOpenShifts = selectedPumpId > 0
            ? openShifts.Where(x => x.PumpId == selectedPumpId).ToList()
            : openShifts;
        var firstShiftId = pumpOpenShifts.FirstOrDefault()?.Id ?? openShifts.FirstOrDefault()?.Id ?? 0;
        var firstProduct = products.FirstOrDefault();
        var firstNozzle = nozzles.FirstOrDefault()?.NozzleCode;

        ApiReceiptDto? latestReceipt = null;
        if (TempData["LatestReceipt"] is string receiptJson)
        {
            try
            {
                latestReceipt = System.Text.Json.JsonSerializer.Deserialize<ApiReceiptDto>(receiptJson);
            }
            catch
            {
                // Ignore serialization errors
            }
        }

        return new SalesManagementViewModel
        {
            Form = new SalesForm
            {
                OwnerId = ownerId,
                PumpId = selectedPumpId,
                ShiftId = firstShiftId,
                // Pehle yahan pehli party apne aap chun jaati thi — Cash sale me bhi
                // ek credit party selected dikhti thi, jo galti se udhaar me jaa sakti
                // thi. Ab khaali rehta hai; Credit mode me user khud chunega.
                PartyId = null,
                Items = new List<SalesLineForm>
                {
                    new()
                    {
                        ProductId = firstProduct?.Id ?? 0,
                        NozzleNo = firstNozzle,
                        Rate = firstProduct?.CurrentRate ?? 0
                    }
                }
            },
            Pumps = pumps,
            Nozzles = nozzles,
            OpenShifts = openShifts,
            LinkableShifts = BuildLinkableShifts(shifts, selectedPumpId),
            Products = products,
            Parties = parties,
            Sales = sales,
            LatestReceipt = latestReceipt,
            Message = TempData["SalesMessage"] as string,
            SearchTerm = searchTerm,
            FromDate = fromDate,
            ToDate = toDate,
            PageNumber = pageNumber,
            PageSize = pageSize
        };
    }

    private async Task<UserManagementViewModel> BuildUserViewModelAsync(long? editId, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null)
        {
            return new UserManagementViewModel();
        }

        var ownerId = GetOwnerId();
        var roles = await apiClient.GetRolesAsync(token, ownerId, cancellationToken);
        var users = await apiClient.GetUsersAsync(token, ownerId, cancellationToken);
        var editItem = editId is null ? null : users.FirstOrDefault(x => x.Id == editId.Value);

        return new UserManagementViewModel
        {
            Form = new UserForm
            {
                Id = editItem?.Id,
                OwnerId = ownerId,
                FullName = editItem?.FullName ?? string.Empty,
                Username = editItem?.Username ?? string.Empty,
                Password = string.Empty,
                Mobile = editItem?.Mobile,
                RoleId = editItem?.RoleId ?? roles.FirstOrDefault()?.Id ?? 0
            },
            Users = users,
            Roles = roles,
            Message = TempData["UserMessage"] as string
        };
    }

    private async Task<StaffManagementViewModel> BuildStaffViewModelAsync(long? pumpId, long? editId, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null)
        {
            return new StaffManagementViewModel();
        }

        var ownerId = GetOwnerId();
        var pumps = await apiClient.GetPumpsAsync(token, ownerId, cancellationToken);
        var selectedPumpId = pumpId ?? pumps.FirstOrDefault()?.Id ?? 0;
        var roles = await apiClient.GetRolesAsync(token, ownerId, cancellationToken);
        var staff = selectedPumpId > 0
            ? await apiClient.GetStaffAsync(token, ownerId, selectedPumpId, cancellationToken)
            : Array.Empty<ApiStaffDto>();

        var editItem = editId is null ? null : staff.FirstOrDefault(x => x.Id == editId.Value);
        var hasLogin = editItem?.UserId is > 0;

        return new StaffManagementViewModel
        {
            Form = new StaffForm
            {
                Id = editItem?.Id,
                OwnerId = ownerId,
                PumpId = selectedPumpId,
                EmployeeCode = editItem?.EmployeeCode ?? GenerateNextEmployeeCode(staff),
                FullName = editItem?.FullName ?? string.Empty,
                Mobile = editItem?.Mobile,
                JoinDate = editItem?.JoinDate ?? DateOnly.FromDateTime(DateTime.Today),
                Designation = editItem?.Designation,
                MonthlySalary = editItem?.MonthlySalary ?? 0,
                IsActive = editItem?.IsActive ?? true,
                WantsLogin = hasLogin,
                Username = editItem?.UserName,
                Password = null,
                RoleId = editItem?.RoleId,
                HasExistingLogin = hasLogin
            },
            Pumps = pumps,
            Roles = roles.Where(x => x.IsActive).OrderBy(x => x.Name).ToList(),
            Staff = staff,
            Message = TempData["StaffMessage"] as string
        };
    }

    private async Task<EmployeeManagementViewModel> BuildEmployeeViewModelAsync(long? pumpId, long? editId, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null)
        {
            return new EmployeeManagementViewModel();
        }

        var ownerId = GetOwnerId();
        var pumps = await apiClient.GetPumpsAsync(token, ownerId, cancellationToken);
        var selectedPumpId = pumpId ?? pumps.FirstOrDefault()?.Id ?? 0;
        var users = await apiClient.GetUsersAsync(token, ownerId, cancellationToken);
        var employees = selectedPumpId > 0
            ? await apiClient.GetEmployeesAsync(token, ownerId, selectedPumpId, cancellationToken)
            : Array.Empty<ApiEmployeeDto>();
        var editItem = editId is null ? null : employees.FirstOrDefault(x => x.Id == editId.Value);

        return new EmployeeManagementViewModel
        {
            Form = new EmployeeForm
            {
                Id = editItem?.Id,
                OwnerId = ownerId,
                PumpId = selectedPumpId,
                UserId = editItem?.UserId,
                EmployeeCode = editItem?.EmployeeCode ?? GenerateNextEmployeeCode(employees),
                FullName = editItem?.FullName ?? string.Empty,
                Mobile = editItem?.Mobile,
                JoinDate = editItem?.JoinDate ?? DateOnly.FromDateTime(DateTime.Today),
                Designation = editItem?.Designation,
                MonthlySalary = editItem?.MonthlySalary ?? 0,
                IsActive = editItem?.IsActive ?? true
            },
            Pumps = pumps,
            Users = users.Where(x => x.IsActive).OrderBy(x => x.FullName).ToList(),
            Employees = employees,
            Message = TempData["EmployeeMessage"] as string
        };
    }

    private async Task<SalaryManagementViewModel> BuildSalaryViewModelAsync(long? pumpId, int? salaryYear, int? salaryMonth, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null)
        {
            return new SalaryManagementViewModel();
        }

        var ownerId = GetOwnerId();
        var year = salaryYear is > 2000 ? salaryYear.Value : DateTime.Today.Year;
        var month = salaryMonth is >= 1 and <= 12 ? salaryMonth.Value : DateTime.Today.Month;

        var pumps = await apiClient.GetPumpsAsync(token, ownerId, cancellationToken);
        var selectedPumpId = pumpId ?? pumps.FirstOrDefault()?.Id ?? 0;
        var employees = selectedPumpId > 0
            ? await apiClient.GetEmployeesAsync(token, ownerId, selectedPumpId, cancellationToken)
            : Array.Empty<ApiEmployeeDto>();
        var payments = selectedPumpId > 0
            ? await apiClient.GetSalaryPaymentsAsync(token, ownerId, selectedPumpId, year, month, cancellationToken)
            : Array.Empty<ApiSalaryPaymentDto>();

        return new SalaryManagementViewModel
        {
            Form = new SalaryPaymentForm
            {
                OwnerId = ownerId,
                PumpId = selectedPumpId,
                EmployeeId = employees.FirstOrDefault()?.Id ?? 0,
                SalaryYear = year,
                SalaryMonth = month,
                Amount = employees.FirstOrDefault()?.MonthlySalary ?? 0,
                PaidOn = DateOnly.FromDateTime(DateTime.Today),
                PaymentMode = "Cash"
            },
            Pumps = pumps,
            Employees = employees.Where(x => x.IsActive).OrderBy(x => x.FullName).ToList(),
            Payments = payments,
            SalaryYear = year,
            SalaryMonth = month,
            Message = TempData["SalaryMessage"] as string
        };
    }

    private async Task<RoleManagementViewModel> BuildRoleViewModelAsync(long? editId, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null)
        {
            return new RoleManagementViewModel();
        }

        var ownerId = GetOwnerId();
        var roles = await apiClient.GetRolesAsync(token, ownerId, cancellationToken);
        var editItem = editId is null ? null : roles.FirstOrDefault(x => x.Id == editId.Value);

        return new RoleManagementViewModel
        {
            Form = new RoleForm
            {
                Id = editItem?.Id,
                OwnerId = ownerId,
                Name = editItem?.Name ?? string.Empty,
                IsSystem = editItem?.IsSystem ?? false
            },
            Roles = roles,
            Message = TempData["RoleMessage"] as string
        };
    }

    private string? GetToken()
    {
        var token = HttpContext.Session.GetString("access_token");
        return string.IsNullOrWhiteSpace(token) ? null : token;
    }

    private long GetOwnerId()
    {
        var ownerIdString = HttpContext.Session.GetString("owner_id");
        return long.TryParse(ownerIdString, out var ownerId) ? ownerId : 1;
    }

    /// <summary>
    /// Login kiya hua user. Shift kholte waqt agar koi in-charge nahi chuna gaya to
    /// yahi zimmedar maana jaata hai — jo shift khol raha hai wahi uska zimmedar hai.
    /// </summary>
    private long? GetUserId()
    {
        var userIdString = HttpContext.Session.GetString("user_id");
        return long.TryParse(userIdString, out var userId) && userId > 0 ? userId : null;
    }

    private async Task<VendorManagementViewModel> BuildVendorViewModelAsync(long? pumpId, long? editId, CancellationToken cancellationToken)
    {
        var token = GetToken();
        if (token is null)
        {
            return new VendorManagementViewModel();
        }

        var ownerId = GetOwnerId();
        var pumps = await apiClient.GetPumpsAsync(token, ownerId, cancellationToken);
        var selectedPumpId = pumpId ?? pumps.FirstOrDefault()?.Id ?? 0;
        var vendors = selectedPumpId > 0
            ? await apiClient.GetVendorsAsync(token, ownerId, selectedPumpId, cancellationToken)
            : Array.Empty<ApiVendorDto>();

        var editVendor = editId.HasValue ? vendors.FirstOrDefault(v => v.Id == editId.Value) : null;

        return new VendorManagementViewModel
        {
            Form = editVendor is not null
                ? new VendorForm
                {
                    Id = editVendor.Id,
                    OwnerId = ownerId,
                    PumpId = selectedPumpId,
                    VendorName = editVendor.VendorName,
                    ContactNo = editVendor.ContactNo,
                    GSTIN = editVendor.GSTIN,
                    Address = editVendor.Address,
                    IsActive = editVendor.IsActive
                }
                : new VendorForm
                {
                    OwnerId = ownerId,
                    PumpId = selectedPumpId,
                    IsActive = true
                },
            Pumps = pumps,
            Vendors = vendors,
            Message = TempData["VendorMessage"] as string
        };
    }



    /// <summary>
    /// Sabse bada EMP-NNN number dhoondh kar agla de deta hai.
    /// Staff aur Employee dono ke liye kaam karta hai — dono me EmployeeCode hota hai.
    /// </summary>
    private static string GenerateNextEmployeeCode<T>(IReadOnlyList<T> existingItems)
    {
        var maxNumber = 0;
        foreach (var item in existingItems)
        {
            var code = item switch
            {
                ApiStaffDto s => s.EmployeeCode,
                ApiEmployeeDto e => e.EmployeeCode,
                _ => null
            };
            if (code is not null
                && code.StartsWith("EMP-", StringComparison.OrdinalIgnoreCase)
                && int.TryParse(code.AsSpan(4), out var num)
                && num > maxNumber)
            {
                maxNumber = num;
            }
        }
        return $"EMP-{maxNumber + 1:D3}";
    }

}
