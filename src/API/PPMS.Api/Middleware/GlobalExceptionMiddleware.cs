using System.Net;
using System.Text.Json;
using PPMS.Shared;

namespace PPMS.Api.Middleware;

public sealed class GlobalExceptionMiddleware(
    RequestDelegate next,
    ILogger<GlobalExceptionMiddleware> logger,
    IWebHostEnvironment environment)
{
    public async Task InvokeAsync(HttpContext context)
    {
        try
        {
            await next(context);
        }
        // Tenant resolve na ho paaye to ye 500 nahi, 401 hai — token hi bekaar hai.
        // Client isse dekh kar token refresh karega, error page nahi dikhayega.
        catch (UnauthorizedAccessException ex)
        {
            logger.LogWarning(ex, "Unauthorized request for {Path}", context.Request.Path);

            if (context.Response.HasStarted)
            {
                throw;
            }

            context.Response.StatusCode = (int)HttpStatusCode.Unauthorized;
            context.Response.ContentType = "application/json";

            await context.Response.WriteAsync(JsonSerializer.Serialize(new ApiResponse<object>
            {
                Success = false,
                Message = ex.Message,
                Data = null
            }));
        }
        // Business rule tooti hai (jaise -50 litre ki sale, ya 2030 ki tareekh) — ye
        // server ki galti nahi hai, isliye 500 nahi 400 dena chahiye aur asli wajah
        // user tak pahunchni chahiye. Pehle ye 500 ban kar "An unexpected error
        // occurred" dikhata tha aur user ko kuch samajh nahi aata tha.
        catch (InvalidOperationException ex)
        {
            logger.LogWarning(ex, "Validation failed for {Path}", context.Request.Path);

            if (context.Response.HasStarted)
            {
                throw;
            }

            context.Response.StatusCode = (int)HttpStatusCode.BadRequest;
            context.Response.ContentType = "application/json";

            await context.Response.WriteAsync(JsonSerializer.Serialize(new ApiResponse<object>
            {
                Success = false,
                Message = ex.Message,
                Data = null
            }));
        }
        // ── SQL Server se aayi business-rule galtiyaan ─────────────────────────
        // Hamari saari stored procedures apni galtiyaan `THROW 50xxx, 'saaf
        // message', 1` se batati hain — jaise "Please pick the tank this nozzle
        // draws from." SQL Server me 50000 se upar ke number user ke apne hote
        // hain; usse neeche ke system ke.
        //
        // Pehle ye yahan tak pahunchte hi nahi the: har endpoint ko apna alag
        // catch likhna padta tha. Jahan wo likhna bhool gaye (matlab zyadatar
        // jagah) wahan SP ka saaf message 500 "An unexpected error occurred."
        // ban jaata tha — user ko bas "Unable to save" dikhta aur karna kya hai
        // kabhi pata nahi chalta.
        //
        // Ab ek hi jagah: apna THROW = 400 + wahi message, har endpoint par.
        catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number >= 50000)
        {
            logger.LogWarning(ex, "Business rule failed for {Path}", context.Request.Path);

            if (context.Response.HasStarted)
            {
                throw;
            }

            context.Response.StatusCode = (int)HttpStatusCode.BadRequest;
            context.Response.ContentType = "application/json";

            await context.Response.WriteAsync(JsonSerializer.Serialize(new ApiResponse<object>
            {
                Success = false,
                Message = ex.Message,
                Data = null
            }));
        }
        // Unique / foreign key tootne par SQL ka apna message constraint ke naam
        // ugal deta hai ("UQ__Users__536C85E4..."). Wo user ke kisi kaam ka nahi,
        // aur DB ka dhaancha bhi bata deta hai. Isliye apna saaf message.
        catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number is 2627 or 2601)
        {
            logger.LogWarning(ex, "Duplicate value for {Path}", context.Request.Path);

            if (context.Response.HasStarted)
            {
                throw;
            }

            context.Response.StatusCode = (int)HttpStatusCode.BadRequest;
            context.Response.ContentType = "application/json";

            await context.Response.WriteAsync(JsonSerializer.Serialize(new ApiResponse<object>
            {
                Success = false,
                Message = "This entry already exists. Please check the code or name and try again.",
                Data = null
            }));
        }
        catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number == 547)
        {
            logger.LogWarning(ex, "Foreign key violation for {Path}", context.Request.Path);

            if (context.Response.HasStarted)
            {
                throw;
            }

            context.Response.StatusCode = (int)HttpStatusCode.BadRequest;
            context.Response.ContentType = "application/json";

            await context.Response.WriteAsync(JsonSerializer.Serialize(new ApiResponse<object>
            {
                Success = false,
                Message = "Something you selected no longer exists, or is still in use somewhere else. "
                          + "Please refresh the page and try again.",
                Data = null
            }));
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Unhandled exception for {Path}", context.Request.Path);

            if (context.Response.HasStarted)
            {
                throw;
            }

            context.Response.StatusCode = (int)HttpStatusCode.InternalServerError;
            context.Response.ContentType = "application/json";

            var payload = new ApiResponse<object>
            {
                Success = false,
                Message = environment.IsDevelopment() ? ex.Message : "An unexpected error occurred.",
                Data = null
            };

            await context.Response.WriteAsync(JsonSerializer.Serialize(payload));
        }
    }
}
