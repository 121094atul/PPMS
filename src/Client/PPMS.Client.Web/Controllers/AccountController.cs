using Microsoft.AspNetCore.Mvc;
using PPMS.Client.Web.Models;
using PPMS.Client.Web.Services;

namespace PPMS.Client.Web.Controllers;

public class AccountController(PPMSApiClient apiClient) : Controller
{
    [HttpGet]
    public IActionResult Login()
    {
        if (!string.IsNullOrWhiteSpace(HttpContext.Session.GetString("access_token")))
        {
            return RedirectToAction("Index", "Home");
        }

        ViewData["Title"] = "Login";
        return View(new LoginViewModel());
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Login(LoginViewModel model,
        [FromServices] Microsoft.Extensions.Localization.IStringLocalizer<SharedResource> localizer,
        CancellationToken cancellationToken)
    {
        ViewData["Title"] = "Login";
        if (string.IsNullOrWhiteSpace(model.Username) || string.IsNullOrWhiteSpace(model.Password))
        {
            model.ErrorMessage = localizer["Username and password are required."].Value;
            return View(model);
        }

        var result = await apiClient.LoginAsync(model.Username, model.Password, cancellationToken);
        if (!result.IsSuccess || result.Data is null)
        {
            // Code se sandesh - plan khatam hua owner ko "API returned 403" nahi,
            // saaf baat dikhni chahiye (aur page support ka number bhi dikhata hai).
            model.ErrorCode = result.ErrorCode;
            model.ErrorMessage = result.ErrorCode == "ACCOUNT_LOCKED" && result.LockMinutes is int minutes
                ? localizer["Too many failed login attempts. Try again after {0} minutes.", minutes].Value
                : localizer[result.ErrorMessage ?? "Unable to login."].Value;
            return View(model);
        }

        var login = result.Data;

        HttpContext.Session.SetString("access_token", login.Token);
        HttpContext.Session.SetString("refresh_token", login.RefreshToken);
        HttpContext.Session.SetString("access_token_expires_utc", login.AccessTokenExpiresOnUtc.ToString("O"));
        HttpContext.Session.SetString("refresh_token_expires_utc", login.RefreshTokenExpiresOnUtc.ToString("O"));
        HttpContext.Session.SetString("full_name", login.FullName);
        HttpContext.Session.SetString("username", login.Username);
        HttpContext.Session.SetString("owner_id", login.OwnerId.ToString());
        HttpContext.Session.SetString("user_id", login.UserId.ToString());
        HttpContext.Session.SetString("role_name", login.RoleName);
        HttpContext.Session.SetString("role_id", login.RoleId.ToString());
        HttpContext.Session.SetString("is_super_admin", login.IsSuperAdmin.ToString());

        if (login.IsSuperAdmin)
        {
            return RedirectToAction("Index", "SuperAdmin");
        }

        return RedirectToAction("Index", "Home");
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Logout(CancellationToken cancellationToken)
    {
        var refreshToken = HttpContext.Session.GetString("refresh_token");
        if (!string.IsNullOrWhiteSpace(refreshToken))
        {
            await apiClient.LogoutAsync(refreshToken, cancellationToken);
        }

        HttpContext.Session.Clear();
        return RedirectToAction("Login", "Account");
    }

    [HttpPost]
    [IgnoreAntiforgeryToken]
    public async Task<IActionResult> Signup([FromBody] SignupInput model, CancellationToken cancellationToken)
    {
        if (model is null)
        {
            return BadRequest(new { message = "All fields are required." });
        }

        var (success, message) = await apiClient.SignupAsync(new
        {
            model.PumpName,
            model.ContactName,
            model.ContactNo,
            model.Username,
            model.Password,
            model.City,
            model.StateCode,
            model.Email
        }, cancellationToken);

        return success ? Ok(new { message }) : BadRequest(new { message });
    }

    [HttpPost]
    [IgnoreAntiforgeryToken]
    public async Task<IActionResult> ForgotPassword([FromBody] ForgotPasswordInput model, CancellationToken cancellationToken)
    {
        if (model is null || string.IsNullOrWhiteSpace(model.Mobile))
        {
            return BadRequest();
        }

        var (smsAvailable, message) = await apiClient.ForgotPasswordAsync(model.Mobile.Trim(), cancellationToken);

        // Number registered hai ya nahi - iska farak kabhi bahar nahi jaata.
        // Lekin "SMS ka intezaam hi nahi hai" poore system ki baat hai, isliye wo
        // batana zaroori bhi hai aur surakshit bhi.
        return Ok(new { smsAvailable, message });
    }

    [HttpPost]
    [IgnoreAntiforgeryToken]
    public async Task<IActionResult> ResetPassword([FromBody] ResetPasswordInput model, CancellationToken cancellationToken)
    {
        if (model is null || string.IsNullOrWhiteSpace(model.Mobile) ||
            string.IsNullOrWhiteSpace(model.Otp) || string.IsNullOrWhiteSpace(model.NewPassword))
        {
            return BadRequest(new { message = "All fields are required." });
        }

        var (success, message) = await apiClient.ResetPasswordAsync(
            model.Mobile.Trim(), model.Otp.Trim(), model.NewPassword, cancellationToken);

        return success ? Ok(new { message }) : BadRequest(new { message });
    }

    [HttpPost]
    public async Task<IActionResult> SubmitSubscriptionRequest([FromBody] ApiSaveSubscriptionRequest model, CancellationToken cancellationToken)
    {
        if (model is null || string.IsNullOrWhiteSpace(model.ContactName) || string.IsNullOrWhiteSpace(model.ContactNo))
        {
            return BadRequest();
        }

        var success = await apiClient.SubmitSubscriptionRequestAsync(model, cancellationToken);
        if (success.Success)
        {
            return Ok();
        }
        return BadRequest(success.ErrorMessage ?? "Could not submit your request.");
    }
}

public sealed record SignupInput(
    string PumpName, string ContactName, string ContactNo,
    string Username, string Password,
    string? City, string? StateCode, string? Email);

public sealed record ForgotPasswordInput(string Mobile);
public sealed record ResetPasswordInput(string Mobile, string Otp, string NewPassword);
