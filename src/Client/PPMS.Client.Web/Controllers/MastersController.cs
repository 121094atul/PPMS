using Microsoft.AspNetCore.Mvc;
using PPMS.Client.Web.Filters;
using PPMS.Client.Web.Services;

namespace PPMS.Client.Web.Controllers;

[SessionAuthorize]
public class MastersController(PPMSApiClient apiClient) : Controller
{
    private readonly PPMSApiClient _apiClient = apiClient;

    private string? GetToken() => HttpContext.Session.GetString("access_token");
    private long GetOwnerId()
    {
        var ownerIdString = HttpContext.Session.GetString("owner_id");
        return long.TryParse(ownerIdString, out var ownerId) ? ownerId : 1;
    }
    private long GetPumpId() => 1; // Default for now until multiple pumps are supported

    public IActionResult Tanks()
    {
        return View();
    }

    [HttpGet]
    public async Task<IActionResult> GetTanks(string? searchTerm, int pageNumber = 1, int pageSize = 10)
    {
        var token = GetToken();
        if (string.IsNullOrWhiteSpace(token))
        {
            return Json(new { success = false, message = "Session expired." });
        }

        var data = await _apiClient.GetTanksAsync(token, GetOwnerId(), GetPumpId(), searchTerm, pageNumber, pageSize);
        return Json(new { success = true, data });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> SaveTank([FromBody] ApiSaveTankRequest request)
    {
        var token = GetToken();
        if (string.IsNullOrWhiteSpace(token))
        {
            return Json(new { success = false, message = "Session expired." });
        }

        request = request with { OwnerId = GetOwnerId(), PumpId = GetPumpId() };
        var success = await _apiClient.SaveTankAsync(token, request);
        return Json(new { success });
    }

    public IActionResult Parties()
    {
        return View();
    }

    [HttpGet]
    public async Task<IActionResult> GetParties(string? searchTerm, int pageNumber = 1, int pageSize = 10)
    {
        var token = GetToken();
        if (string.IsNullOrWhiteSpace(token))
        {
            return Json(new { success = false, message = "Session expired." });
        }

        var data = await _apiClient.GetPartiesAsync(token, GetOwnerId(), GetPumpId(), searchTerm, pageNumber, pageSize);
        return Json(new { success = true, data });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> SaveParty([FromBody] ApiSavePartyRequest request)
    {
        var token = GetToken();
        if (string.IsNullOrWhiteSpace(token))
        {
            return Json(new { success = false, message = "Session expired." });
        }

        request = request with { OwnerId = GetOwnerId(), PumpId = GetPumpId() };
        var success = await _apiClient.SavePartyAsync(token, request);
        return Json(new { success });
    }
}
