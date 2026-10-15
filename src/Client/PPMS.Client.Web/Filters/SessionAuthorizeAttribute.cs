using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Filters;

namespace PPMS.Client.Web.Filters;

[AttributeUsage(AttributeTargets.Class | AttributeTargets.Method)]
public sealed class SessionAuthorizeAttribute : Attribute, IAuthorizationFilter
{
    public void OnAuthorization(AuthorizationFilterContext context)
    {
        var token = context.HttpContext.Session.GetString("access_token");
        if (!string.IsNullOrWhiteSpace(token))
        {
            return;
        }

        context.Result = new RedirectToActionResult("Login", "Account", null);
    }
}
