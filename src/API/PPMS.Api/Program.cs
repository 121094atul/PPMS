using System.Security.Claims;
using System.Text;
using System.Threading.RateLimiting;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.AspNetCore.HttpOverrides;
using Microsoft.AspNetCore.RateLimiting;
using Microsoft.Extensions.Logging;
using Microsoft.IdentityModel.Tokens;
using PPMS.Api.Middleware;
using PPMS.Application;
using PPMS.Application.Features.Auth;
using PPMS.Application.Features.Menus;
using PPMS.Application.Features.Nozzles;
using PPMS.Application.Features.Pumps;
using PPMS.Application.Features.Products;
using PPMS.Application.Features.Roles;
using PPMS.Application.Features.Sales;
using PPMS.Application.Features.Shifts;
using PPMS.Application.Features.Tanks;
using PPMS.Application.Features.Users;
using PPMS.Application.Features.Parties;
using PPMS.Application.Features.TankTransactions;
using PPMS.Application.Features.PartyLedger;
using PPMS.Application.Features.Vendors;
using PPMS.Application.Features.Purchases;
using PPMS.Application.Features.StockReconciliation;
using PPMS.Application.Features.ExpenseHeads;
using PPMS.Application.Features.CashTransactions;
using PPMS.Application.Features.Expenses;
using PPMS.Application.Features.DayBookReport;
using PPMS.Application.Features.ReportInsights;
using PPMS.Application.Features.FleetCoupons;
using PPMS.Application.Features.Employees;
using PPMS.Application.Features.SalaryPayments;
using PPMS.Application.Features.DipTesting;
using PPMS.Infrastructure;
using PPMS.Infrastructure.Security;
using PPMS.Api.Tenancy;
using PPMS.Application.Interfaces;

var builder = WebApplication.CreateBuilder(new WebApplicationOptions
{
    Args = args,
    // Always resolve appsettings from the app directory to avoid empty ConnectionString
    // when exe is started from a different working directory.
    ContentRootPath = AppContext.BaseDirectory
});
builder.Logging.ClearProviders();
builder.Logging.AddConsole();
var jwtSection = builder.Configuration.GetSection(JwtOptions.SectionName);
var jwtOptions = jwtSection.Get<JwtOptions>() ?? new JwtOptions();

// ── JWT key ki jaanch — production me kamzor key par app chalega hi nahi ──────
//
// JWT key is poore system ki master chaabi hai. Jiske paas ye hai wo apna token
// khud bana sakta hai — `is_super_admin=true` daal kar, bina password ke, har
// tenant ka data. Isliye iska galat hona chup-chaap nahi jaana chahiye.
//
// Pehle koi jaanch thi hi nahi: env var set karna bhool jao to app JwtOptions ka
// default ("ChangeThisKey_AtLeast32Chars_Long!") le kar chalu ho jaata — aur wo
// default source code me likha hua hai, yaani sab jaante hain.
//
// Development me rok nahi hai (wahan local key se hi kaam chalta hai).
if (!builder.Environment.IsDevelopment())
{
    var badKeys = new[]
    {
        "ChangeThisKey_AtLeast32Chars_Long!",                        // JwtOptions ka default
        "PPMS_J4v8sK2nL9qF3xY7mW1cR6eT0pA5dH_OVERRIDE_VIA_ENV",      // appsettings.json me pada hua
        "PPMS_LOCAL_DEV_ONLY_KEY_DO_NOT_USE_IN_PRODUCTION_9f3a7c",   // dev wali
    };

    if (string.IsNullOrWhiteSpace(jwtOptions.Key))
    {
        throw new InvalidOperationException(
            "Jwt:Key is not set. Set the Jwt__Key environment variable on the server. "
            + "Never put it in appsettings.json.");
    }

    // HMAC-SHA256 ke liye kam se kam 256 bit (32 byte) chahiye.
    if (Encoding.UTF8.GetByteCount(jwtOptions.Key) < 32)
    {
        throw new InvalidOperationException(
            "Jwt:Key is too short. HMAC-SHA256 needs at least 32 bytes (32 plain characters); use 64+.");
    }

    if (badKeys.Contains(jwtOptions.Key, StringComparer.Ordinal))
    {
        throw new InvalidOperationException(
            "Jwt:Key is still one of the keys committed to the repository, so it is public knowledge. "
            + "Generate a new one and set it via the Jwt__Key environment variable.");
    }
}

var signingKey = new SymmetricSecurityKey(Encoding.UTF8.GetBytes(jwtOptions.Key));

builder.Services.AddEndpointsApiExplorer();
builder.Services.AddSwaggerGen();
builder.Services.AddApplicationServices();
builder.Services.AddInfrastructureServices(builder.Configuration);

// Tenant isolation — har request ka owner sirf JWT claim se aata hai.
builder.Services.Configure<TenantOptions>(builder.Configuration.GetSection(TenantOptions.SectionName));
builder.Services.AddScoped<TenantContext>();
builder.Services.AddScoped<ITenantContext>(sp => sp.GetRequiredService<TenantContext>());
builder.Services.AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
    .AddJwtBearer(options =>
    {
        options.TokenValidationParameters = new TokenValidationParameters
        {
            ValidateIssuer = true,
            ValidateAudience = true,
            ValidateLifetime = true,
            ValidateIssuerSigningKey = true,
            ValidIssuer = jwtOptions.Issuer,
            ValidAudience = jwtOptions.Audience,
            IssuerSigningKey = signingKey
        };
    });
builder.Services.AddAuthorization(options =>
{
    options.AddPolicy("SuperAdminOnly", policy =>
        policy.RequireClaim("is_super_admin", "true"));
});

// CORS pehle AllowAnyOrigin + AllowAnyMethod + AllowAnyHeader tha — yaani duniya ki
// koi bhi website browser se is API ko call kar sakti thi.
//
// Asli baat ye hai ki iski ZAROORAT hi nahi: PPMS.Client.Web ek server-side MVC app
// hai jo API ko apne server se (HttpClient) bulaati hai, browser se nahi. Poore
// wwwroot/Views me API ka koi seedha call hai hi nahi — check kiya gaya.
//
// Isliye ab origin config se aate hain. Cors:AllowedOrigins khaali ho to koi bhi
// origin allow NAHI hota (server-to-server call par CORS lagta hi nahi, wo chalti
// rahegi). Aage kabhi mobile app ya alag front-end jodna ho to yahan uska origin
// daal dein.
var corsOrigins = builder.Configuration.GetSection("Cors:AllowedOrigins").Get<string[]>()
                  ?? Array.Empty<string>();
builder.Services.AddCors(options =>
{
    options.AddDefaultPolicy(policy =>
    {
        if (corsOrigins.Length > 0)
        {
            policy.WithOrigins(corsOrigins)
                  .AllowAnyMethod()
                  .AllowAnyHeader()
                  .AllowCredentials();
        }
        // warna: koi origin allow nahi — browser se cross-site call band.
    });
});

builder.Services.AddRateLimiter(options =>
{
    // Pehle ek hi global bucket tha — 10 requests/minute POORE INDIA ke liye total,
    // isliye subah shift-change par sab lock ho jaate the. Ab per-IP partition hai,
    // saath me AuthService me per-username DB lockout (sp_LoginAttempt_IsLocked) bhi hai.
    options.AddPolicy("login", httpContext =>
        RateLimitPartition.GetSlidingWindowLimiter(
            partitionKey: httpContext.Connection.RemoteIpAddress?.ToString() ?? "unknown",
            factory: _ => new SlidingWindowRateLimiterOptions
            {
                PermitLimit = 10,
                Window = TimeSpan.FromSeconds(60),
                SegmentsPerWindow = 2,
                QueueLimit = 0
            }));

    // Trial-request wala endpoint LOGIN PAGE par hai — bina login ke koi bhi hit kar
    // sakta hai. Test me ek hi IP se 15 ki 15 request chali gayi thi, yaani koi bhi
    // superadmin ki request list bhar sakta tha. Trial ek baar maanga jaata hai, roz
    // 5 se zyada nahi — isliye ghanta bhar ki khidki rakhi hai.
    options.AddPolicy("public-form", httpContext =>
        RateLimitPartition.GetFixedWindowLimiter(
            partitionKey: httpContext.Connection.RemoteIpAddress?.ToString() ?? "unknown",
            factory: _ => new FixedWindowRateLimiterOptions
            {
                PermitLimit = 5,
                Window = TimeSpan.FromMinutes(60),
                QueueLimit = 0
            }));

    options.RejectionStatusCode = 429;
});

var app = builder.Build();

// IIS reverse proxy ke peeche asli client IP aur scheme lautana.
//
// UAT/production par shared hosting hai, isliye API `hostingModel="outofprocess"`
// me chalti hai (ek hi app pool me client + API — in-process me dono nahi chal
// sakte). Us model me IIS TLS khud khatam karta hai aur Kestrel ko plain HTTP
// forward karta hai — matlab Kestrel ko har request localhost se aati dikhti hai.
//
// Uske do nateeje the:
//   1. Rate limiter `RemoteIpAddress` se partition karta hai. Sabki IP 127.0.0.1
//      ho jaati, yaani SAARE users ka ek hi quota — ek banda login limit kha kar
//      baaki sabko bhi bahar kar sakta tha, aur brute-force ki rok bekaar ho jaati.
//   2. LoginAttempts aur SubscriptionRequests.SourceIp me bhi 127.0.0.1 hi likha
//      jaata — kuch galat ho to pata hi nahi chalta ki kahan se hua.
//
// ANCM `X-Forwarded-For`/`X-Forwarded-Proto` bhejta hai; default KnownProxies me
// loopback pehle se hai, isliye sirf loopback se aaye headers hi maane jaate hain.
app.UseForwardedHeaders(new ForwardedHeadersOptions
{
    ForwardedHeaders = ForwardedHeaders.XForwardedFor | ForwardedHeaders.XForwardedProto
});

// Swagger har jagah khula tha — production par bhi. Usse hamla karne wale ko poora
// naqsha mil jaata hai: har endpoint, har parameter, har request body ka shape.
// Ab sirf Development me.
if (app.Environment.IsDevelopment())
{
    app.UseSwagger();
    app.UseSwaggerUI(options =>
    {
        options.SwaggerEndpoint("/swagger/v1/swagger.json", "PPMS API v1");
        options.RoutePrefix = "swagger";
    });
}

// Security headers — ye pehle bilkul nahi the.
app.Use(async (ctx, next) =>
{
    var h = ctx.Response.Headers;
    h["X-Content-Type-Options"] = "nosniff";        // browser content-type guess na kare
    h["X-Frame-Options"] = "DENY";                  // iframe me daal kar clickjacking na ho
    h["Referrer-Policy"] = "no-referrer";           // URL doosri site tak na jaye
    h["X-Permitted-Cross-Domain-Policies"] = "none";

    // HSTS — browser ko keh dete hain "is host par hamesha HTTPS hi use karna".
    // Client (ppms) par ye pehle se aa raha tha, API par nahi tha. Bina iske
    // pehli request http par ja sakti hai, aur usi ek request me token chori
    // ho sakta hai. Sirf HTTPS par bhejte hain — http par bhejna spec ke
    // khilaf hai aur browser use andekha kar deta hai.
    if (ctx.Request.IsHttps)
        h["Strict-Transport-Security"] = "max-age=2592000";   // 30 din

    await next();
});

app.UseMiddleware<GlobalExceptionMiddleware>();
app.UseCors();
app.UseRateLimiter();
app.UseAuthentication();

// Authentication ke turant baad, authorization se pehle. Yahan tak aate-aate
// ctx.User bhar chuka hota hai, aur model binding abhi hui nahi hai — isliye
// query string aur request body dono ko yahan theek kiya ja sakta hai.
app.UseMiddleware<TenantIsolationMiddleware>();

app.UseAuthorization();

app.MapGet("/api/health", () => Results.Ok(new
{
    Status = "OK",
    Service = "PPMS API",
    UtcTime = DateTime.UtcNow
}));

app.MapGet("/api/products/categories", () =>
{
    return Results.Ok(new[]
    {
        "Petrol",
        "Diesel",
        "CNG",
        "ElectricCharging",
        "Lubricant",
        "Accessory"
    });
});

// TENANT ISOLATION
// ----------------
// Pehle ye function client ka bheja hua ownerId maan leta tha:
//
//     if (requestedOwnerId is > 0) return requestedOwnerId.Value;   // <-- IDOR
//     ...
//     return long.TryParse(ownerIdValue, out var claimOwnerId) ? claimOwnerId : 1;   // <-- silent fallback
//
// Do problem thi. Ek, koi bhi logged-in user URL me ?ownerId= badal kar kisi bhi
// doosre pump ka data padh (aur delete kar) sakta tha. Do, claim na mile to chupchaap
// Owner 1 ka data khul jaata tha — error tak nahi aata tha.
//
// Ab OwnerId sirf JWT claim se aata hai. Aam user ke liye requestedOwnerId dekha hi
// nahi jaata; wo parameter isliye bacha hai taaki purane clients ki URL na toote.
// Sirf superadmin hi usse kisi doosre owner ko target kar sakta hai.
//
// TenantIsolationMiddleware isse pehle hi query string aur request body dono ka
// ownerId token wale se replace kar chuka hota hai — ye doosri deewar hai.
static long ResolveOwnerId(ClaimsPrincipal user, long? requestedOwnerId)
{
    var isSuperAdmin = string.Equals(
        user.FindFirstValue(PpmsClaims.IsSuperAdmin), "true", StringComparison.OrdinalIgnoreCase);

    // Superadmin hi kisi doosre owner ko target kar sakta hai.
    if (isSuperAdmin && requestedOwnerId is > 0)
    {
        return requestedOwnerId.Value;
    }

    var ownerIdValue = user.FindFirstValue(PpmsClaims.OwnerId);
    if (long.TryParse(ownerIdValue, out var claimOwnerId) && claimOwnerId > 0)
    {
        return claimOwnerId;
    }

    // Pehle yahan `: 1` tha — token kharab hone par bhi Owner 1 ka data khul jaata tha.
    // Ab saaf mana kar dete hain.
    throw new UnauthorizedAccessException("Tenant could not be resolved from the access token.");
}

static int ParseLockoutMinutes(string exceptionMessage)
{
    var parts = exceptionMessage.Split(':');
    return parts.Length == 2 && int.TryParse(parts[1], out var minutes) ? minutes : 15;
}

// Primary routes (WAF-friendly names)
app.MapPost("/api/account/access", async (LoginRequest request, HttpContext httpContext, IAuthService service, CancellationToken cancellationToken) =>
{
    try
    {
        var ipAddress = httpContext.Connection.RemoteIpAddress?.ToString();
        var result = await service.LoginAsync(request, ipAddress, cancellationToken);
        return result is null ? Results.Unauthorized() : Results.Ok(result);
    }
    catch (UnauthorizedAccessException ex) when (ex.Message == "TRIAL_EXPIRED")
    {
        return Results.Json(new { error = "TRIAL_EXPIRED", message = "Your plan has expired. Please contact support to renew." }, statusCode: 403);
    }
    catch (UnauthorizedAccessException ex) when (ex.Message.StartsWith("ACCOUNT_LOCKED"))
    {
        var minutes = ParseLockoutMinutes(ex.Message);
        return Results.Json(new { error = "ACCOUNT_LOCKED", message = $"Too many failed login attempts. Try again after {minutes} minutes." }, statusCode: 429);
    }
}).RequireRateLimiting("login");

// Ye /api/auth/refresh ka hi doosra naam hai (WAF-friendly). Suspend/expiry ki rok
// AuthService.RefreshAsync me hai, isliye yahan bhi lagti hai — par uske exceptions
// ka catch yahan nahi tha, to saaf 403 ki jagah generic 401 milta tha.
app.MapPost("/api/account/renew", async (RefreshTokenRequest request, IAuthService service, CancellationToken cancellationToken) =>
{
    try
    {
        var result = await service.RefreshAsync(request, cancellationToken);
        return result is null ? Results.Unauthorized() : Results.Ok(result);
    }
    catch (UnauthorizedAccessException ex) when (ex.Message == "TRIAL_EXPIRED")
    {
        return Results.Json(new { error = "TRIAL_EXPIRED", message = "Your subscription has expired. Please contact support to renew." }, statusCode: 403);
    }
    catch (UnauthorizedAccessException ex) when (ex.Message == "OWNER_SUSPENDED")
    {
        return Results.Json(new { error = "OWNER_SUSPENDED", message = "This account has been suspended. Please contact support." }, statusCode: 403);
    }
});

app.MapPost("/api/account/signout", async (LogoutRequest request, IAuthService service, CancellationToken cancellationToken) =>
{
    await service.LogoutAsync(request, cancellationToken);
    return Results.Ok(new { Success = true });
});

// Login page se naya pump khud account bana le. Pehle sirf "request" jaati thi aur
// superadmin ko haath se tenant banana padta tha — har naye grahak par uska waqt.
// Public hai, isliye per-IP rate limit; SP me ek mobile par ek hi account ki rok.
app.MapPost("/api/account/signup", async (
    PPMS.Application.Features.Owners.SelfSignupRequest request,
    HttpContext http,
    PPMS.Application.Features.Owners.ISelfSignupService service,
    CancellationToken cancellationToken) =>
{
    try
    {
        var result = await service.SignupAsync(request, http.Connection.RemoteIpAddress?.ToString(), cancellationToken);
        return Results.Ok(new
        {
            Success = true,
            OwnerId = result.Id,
            Message = "Account created. You can now sign in with your username and password."
        });
    }
    catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number is >= 50100 and <= 50103)
    {
        // SP ki apni jaanch — username/mobile pehle se hai waghairah. Message
        // seedha user ko dikhana hai, wo saaf Hindi me likha hai.
        return Results.BadRequest(new { Success = false, Message = ex.Message });
    }
}).RequireRateLimiting("public-form");

// ── Password reset (mobile OTP) ─────────────────────────────────────────────
// Dono endpoint bina login ke chalte hain (bhoola hua password hi to reset karna
// hai), isliye per-IP rate limit lagi hai. SP me alag se per-mobile throttle bhi
// hai — ek number par ghante me 3 OTP se zyada nahi.
app.MapPost("/api/account/forgot-password", async (
    RequestOtpRequest request,
    HttpContext http,
    IPasswordResetService service,
    ISupportContactRepository supportContacts,
    CancellationToken cancellationToken) =>
{
    var outcome = await service.RequestOtpAsync(request.Mobile, http.Connection.RemoteIpAddress?.ToString(), cancellationToken);

    // Registered / not-registered me FARAK NAHI batana — warna koi bhi number
    // daal-daal kar pata kar lega ki kaun sa number system me hai. Dono par ek jaisa.
    //
    // Lekin SMS ka intezaam hi na ho, ya bhejne me fail ho jaye — ye poore system ki
    // haalat hai, kisi khaas number ke baare me kuch nahi batati. Isse chhupana ulta
    // nuksaan karta hai: user OTP ka intezaar karta rehta hai jo kabhi aayega hi nahi.
    return outcome switch
    {
        PPMS.Application.Features.Auth.OtpSendOutcome.SmsNotConfigured => Results.Ok(new
        {
            Success = false,
            SmsAvailable = false,
            // Number Super Admin se (Section AR).
            Message = (await supportContacts.GetAsync(cancellationToken)).Display is string support
                ? $"OTP service is not set up yet. Please call support on {support} to reset your password."
                : "OTP service is not set up yet. Please call support to reset your password."
        }),

        /* SendFailed par ALAG jawab dena galat tha — SMS kharab hone par koi bhi
           number daal-daal kar pata kar leta ki kaun sa registered hai (kyunki
           anjaan number par send ki koshish hoti hi nahi, to wo kabhi fail nahi
           hota). Isliye ab iska jawab bhi wahi generic wala hai.

           Fail hone ki khabar server ke log me jaati hai (operator ke liye), aur
           user ko agli screen par "OTP nahi aaya? call karein" ka raasta milta
           hai — jisse wo atka nahi rehta. */
        PPMS.Application.Features.Auth.OtpSendOutcome.SendFailed or
        PPMS.Application.Features.Auth.OtpSendOutcome.Throttled => Results.Ok(new
        {
            Success = true,
            SmsAvailable = true,
            Message = "If this number is registered, an OTP has been sent."
        }),

        _ => Results.Ok(new
        {
            Success = true,
            SmsAvailable = true,
            Message = "If this number is registered, an OTP has been sent."
        })
    };
}).RequireRateLimiting("public-form");

app.MapPost("/api/account/reset-password", async (
    VerifyOtpRequest request,
    IPasswordResetService service,
    CancellationToken cancellationToken) =>
{
    var row = await service.VerifyAsync(request, cancellationToken);

    // SP saaf-saaf batati hai kya hua; wahi user tak pahunchana hai taaki use
    // samajh aaye ki OTP galat hai, purana ho gaya, ya koshishein khatam.
    return row.Result switch
    {
        "OK" => Results.Ok(new { Success = true, Message = "Password changed. You can now sign in with the new password." }),
        "WRONG_OTP" => Results.BadRequest(new { Success = false, Message = $"Incorrect OTP. {row.AttemptsLeft} attempt(s) left." }),
        "EXPIRED" => Results.BadRequest(new { Success = false, Message = "The OTP has expired. Please request a new one." }),
        "TOO_MANY_ATTEMPTS" => Results.BadRequest(new { Success = false, Message = "Too many incorrect attempts. Please request a new OTP." }),
        _ => Results.BadRequest(new { Success = false, Message = "Please request an OTP first." })
    };
}).RequireRateLimiting("public-form");

// Superadmin kisi bhi user ka password reset kar sake — support call par turant
// kaam aata hai. SP khud bhi jaanchti hai ki bulane wala superadmin hi hai.
app.MapPost("/api/users/{id:long}/reset-password", async (
    long id,
    ResetUserPasswordRequest request,
    ClaimsPrincipal user,
    IPasswordResetService service,
    CancellationToken cancellationToken) =>
{
    if (!long.TryParse(user.FindFirstValue(ClaimTypes.NameIdentifier), out var byUserId))
    {
        return Results.Unauthorized();
    }

    await service.AdminResetAsync(id, request.NewPassword, byUserId, cancellationToken);
    return Results.Ok(new { Success = true });
}).RequireAuthorization("SuperAdminOnly");

// Legacy routes (kept for backward compatibility)
app.MapPost("/api/auth/login", async (LoginRequest request, HttpContext httpContext, IAuthService service, CancellationToken cancellationToken) =>
{
    try
    {
        var ipAddress = httpContext.Connection.RemoteIpAddress?.ToString();
        var result = await service.LoginAsync(request, ipAddress, cancellationToken);
        return result is null ? Results.Unauthorized() : Results.Ok(result);
    }
    catch (UnauthorizedAccessException ex) when (ex.Message == "TRIAL_EXPIRED")
    {
        return Results.Json(new { error = "TRIAL_EXPIRED", message = "Your plan has expired. Please contact support to renew." }, statusCode: 403);
    }
    // AuthService "OWNER_SUSPENDED" bhi phenkti hai par yahan uska catch tha hi nahi —
    // suspend kiye gaye owner ko saaf message ki jagah 500 milta tha.
    catch (UnauthorizedAccessException ex) when (ex.Message == "OWNER_SUSPENDED")
    {
        return Results.Json(new { error = "OWNER_SUSPENDED", message = "This account has been suspended. Please contact support." }, statusCode: 403);
    }
    catch (UnauthorizedAccessException ex) when (ex.Message.StartsWith("ACCOUNT_LOCKED"))
    {
        var minutes = ParseLockoutMinutes(ex.Message);
        return Results.Json(new { error = "ACCOUNT_LOCKED", message = $"Too many failed login attempts. Try again after {minutes} minutes." }, statusCode: 429);
    }
}).RequireRateLimiting("login");

app.MapPost("/api/auth/refresh", async (RefreshTokenRequest request, IAuthService service, CancellationToken cancellationToken) =>
{
    // Refresh par bhi ab owner suspend/expiry ka wahi check lagta hai jo login par
    // lagta tha. Uske bina suspend kiya gaya tenant refresh token rotate karke
    // hamesha chalta rehta tha aur suspend lagta hi nahi tha.
    try
    {
        var result = await service.RefreshAsync(request, cancellationToken);
        return result is null ? Results.Unauthorized() : Results.Ok(result);
    }
    catch (UnauthorizedAccessException ex) when (ex.Message == "TRIAL_EXPIRED")
    {
        return Results.Json(new { error = "TRIAL_EXPIRED", message = "Your subscription has expired. Please contact support to renew." }, statusCode: 403);
    }
    catch (UnauthorizedAccessException ex) when (ex.Message == "OWNER_SUSPENDED")
    {
        return Results.Json(new { error = "OWNER_SUSPENDED", message = "This account has been suspended. Please contact support." }, statusCode: 403);
    }
});

app.MapPost("/api/auth/logout", async (LogoutRequest request, IAuthService service, CancellationToken cancellationToken) =>
{
    await service.LogoutAsync(request, cancellationToken);
    return Results.Ok(new { Success = true });
});

// Super Admin / Owners Management
app.MapGet("/api/owners", async (PPMS.Application.Features.Owners.IOwnerService service, CancellationToken cancellationToken) =>
{
    var items = await service.GetAllAsync(cancellationToken);
    return Results.Ok(items);
}).RequireAuthorization("SuperAdminOnly");

app.MapPost("/api/owners", async (PPMS.Application.Features.Owners.SaveOwnerRequest request, PPMS.Application.Features.Owners.IOwnerService service, CancellationToken cancellationToken) =>
{
    var id = await service.SaveAsync(request, cancellationToken);
    return Results.Ok(new { Id = id });
}).RequireAuthorization("SuperAdminOnly");

app.MapPut("/api/owners/{id}/toggle-status", async (long id, PPMS.Application.Features.Owners.IOwnerService service, CancellationToken cancellationToken) =>
{
    await service.ToggleStatusAsync(id, cancellationToken);
    return Results.NoContent();
}).RequireAuthorization("SuperAdminOnly");

// Grahak ka phone aata hai "password bhool gaya" — superadmin ko us tenant ke users
// chahiye taaki sahi wale ka password reset kar sake.
app.MapGet("/api/owners/{id:long}/users", async (long id, PPMS.Application.Features.Owners.IOwnerService service, CancellationToken cancellationToken) =>
{
    var users = await service.GetUsersAsync(id, cancellationToken);
    return Results.Ok(users);
}).RequireAuthorization("SuperAdminOnly");

app.MapPut("/api/owners/{id}/extend-trial", async (long id, PPMS.Application.Features.Owners.ExtendTrialRequest request, PPMS.Application.Features.Owners.IOwnerService service, CancellationToken cancellationToken) =>
{
    await service.ExtendTrialAsync(id, request.NewValidUpto, cancellationToken);
    return Results.NoContent();
}).RequireAuthorization("SuperAdminOnly");

// Subscription Requests — public POST (no auth needed), admin GET/PUT
app.MapPost("/api/subscription-requests", async (
    PPMS.Application.Features.Subscriptions.SaveSubscriptionRequest request,
    HttpContext http,
    PPMS.Application.Features.Subscriptions.ISubscriptionRequestService service,
    CancellationToken cancellationToken) =>
{
    // SourceIp column table me tha lekin bharta koi nahi tha — galat request aane par
    // baad me pata hi nahi chalta ki kahan se aayi. Proxy ke peeche asli IP
    // X-Forwarded-For me hoti hai (UseForwardedHeaders isse RemoteIpAddress me daal
    // deta hai jab known proxy set ho), isliye wahi le rahe hain.
    var sourceIp = http.Connection.RemoteIpAddress?.ToString();

    var id = await service.SaveAsync(request with { SourceIp = sourceIp }, cancellationToken);
    return Results.Ok(new { Id = id });
}).RequireRateLimiting("public-form");

app.MapGet("/api/subscription-requests", async (
    PPMS.Application.Features.Subscriptions.ISubscriptionRequestService service,
    CancellationToken cancellationToken) =>
{
    var items = await service.GetAllAsync(cancellationToken);
    return Results.Ok(items);
}).RequireAuthorization("SuperAdminOnly");

app.MapPut("/api/subscription-requests/{id}/mark-done", async (
    long id,
    PPMS.Application.Features.Subscriptions.ISubscriptionRequestService service,
    CancellationToken cancellationToken) =>
{
    await service.MarkDoneAsync(id, cancellationToken);
    return Results.NoContent();
}).RequireAuthorization("SuperAdminOnly");

app.MapGet("/api/menus/my", async (ClaimsPrincipal user, IMenuQueryService service, CancellationToken cancellationToken) =>
{
    var isSuperAdmin = string.Equals(user.FindFirstValue("is_super_admin"), "true", StringComparison.OrdinalIgnoreCase);
    if (isSuperAdmin)
    {
        return Results.Ok(Array.Empty<MenuItemDto>());
    }

    var roleIdValue = user.FindFirstValue("role_id");
    if (!long.TryParse(roleIdValue, out var roleId))
    {
        return Results.Unauthorized();
    }

    var menus = await service.GetByRoleIdAsync(roleId, cancellationToken);
    return Results.Ok(menus);
}).RequireAuthorization();

app.MapGet("/api/menus", async (IMenuQueryService service, CancellationToken cancellationToken) =>
{
    var menus = await service.GetAllAsync(cancellationToken);
    return Results.Ok(menus);
}).RequireAuthorization();

app.MapGet("/api/products", async (ClaimsPrincipal user, long? ownerId, long? pumpId, IProductQueryService service, CancellationToken cancellationToken) =>
{
    var resolvedOwnerId = ResolveOwnerId(user, ownerId);
    var products = await service.GetAllAsync(resolvedOwnerId, pumpId, cancellationToken);
    return Results.Ok(products);
}).RequireAuthorization();

// Pehle ye sirf product id leta tha — koi bhi id daal kar doosre owner ke product
// ka rate history nikal sakta tha. Ab pehle ownership check hoti hai.
app.MapGet("/api/products/{id:long}/rate-history", async (long id, ClaimsPrincipal user, ITenantGuard guard, IProductQueryService service, CancellationToken cancellationToken) =>
{
    var ownerId = ResolveOwnerId(user, null);
    if (!await guard.OwnsAsync(ownerId, TenantEntities.Product, id, cancellationToken))
    {
        return Results.NotFound();
    }

    var history = await service.GetRateHistoryAsync(id, cancellationToken);
    return Results.Ok(history);
}).RequireAuthorization();

app.MapPost("/api/products", async (SaveProductRequest request, IProductCommandService service, CancellationToken cancellationToken) =>
{
    await service.SaveAsync(request, cancellationToken);
    return Results.Ok(new { Success = true });
}).RequireAuthorization();

// "Aaj ke rate" screen — ek pump par kai fuel grade hote hain (Normal, Premium/XP95,
// E20, Diesel) aur roz subah sabka rate alag aata hai. Ye do endpoint us ek screen
// ke liye hain, taaki har grade ke liye alag se Products form na kholna pade.
app.MapGet("/api/products/daily-rates", async (ClaimsPrincipal user, long? ownerId, long? pumpId, IProductCommandService service, CancellationToken cancellationToken) =>
{
    var resolvedOwnerId = ResolveOwnerId(user, ownerId);
    var rates = await service.GetDailyRatesAsync(resolvedOwnerId, pumpId, cancellationToken);
    return Results.Ok(rates);
}).RequireAuthorization();

app.MapPost("/api/products/daily-rates", async (UpdateDailyRatesRequest request, ClaimsPrincipal user, IProductCommandService service, CancellationToken cancellationToken) =>
{
    // OwnerId hamesha JWT se — body me jo aaya ho use bharosa nahi. SP bhi apni
    // taraf se check karta hai ki product isi owner ka hai.
    var resolvedOwnerId = ResolveOwnerId(user, null);
    long? userId = long.TryParse(user.FindFirstValue(ClaimTypes.NameIdentifier), out var uid) ? uid : null;

    var updated = await service.UpdateDailyRatesAsync(
        request with { OwnerId = resolvedOwnerId }, userId, cancellationToken);

    return Results.Ok(new { Success = true, UpdatedCount = updated });
}).RequireAuthorization();

app.MapDelete("/api/products/{id:long}", async (long id, ClaimsPrincipal user, long? ownerId, IProductCommandService service, CancellationToken cancellationToken) =>
{
    var resolvedOwnerId = ResolveOwnerId(user, ownerId);
    try
    {
        await service.DeleteAsync(id, resolvedOwnerId, cancellationToken);
        return Results.Ok();
    }
    catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number is >= 50040 and <= 50049)
    {
        return Results.BadRequest(ex.Message);
    }
    catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number == 547)
    {
        return Results.BadRequest("Cannot delete this product because it is linked to tanks, nozzles, or sales.");
    }
}).RequireAuthorization();

app.MapGet("/api/tanks", async (ClaimsPrincipal user, long? ownerId, long? pumpId, string? searchTerm, int? pageNumber, int? pageSize, ITankQueryService service, CancellationToken cancellationToken) =>
{
    if (pumpId is null or <= 0)
    {
        return Results.BadRequest("pumpId is required.");
    }

    var resolvedOwnerId = ResolveOwnerId(user, ownerId);
    var pNum = pageNumber ?? 1;
    var pSize = pageSize ?? 10;
    var tanks = await service.GetPagedListAsync(resolvedOwnerId, pumpId.Value, searchTerm, pNum, pSize, cancellationToken);
    return Results.Ok(tanks);
}).RequireAuthorization();

app.MapGet("/api/tanks/{id:long}/stock-as-of", async (ClaimsPrincipal user, long id, DateOnly date, long? ownerId, ITankQueryService service, CancellationToken cancellationToken) =>
{
    var resolvedOwnerId = ResolveOwnerId(user, ownerId);
    var stock = await service.GetStockAsOfDateAsync(id, resolvedOwnerId, date, cancellationToken);
    return Results.Ok(new { Stock = stock });
}).RequireAuthorization();

// Dip ke liye book stock — DSR wala hisaab (Section AB). Owner JWT se hi; SP
// khud bhi tank ka malik jaanchta hai. Stock Reconcile upar wala stock-as-of hi
// use karta rahega — wahan tank ka kitaabi stock hi sahi aadhaar hai.
app.MapGet("/api/tanks/{id:long}/dip-book-stock", async (ClaimsPrincipal user, long id, DateOnly date, ITankQueryService service, CancellationToken cancellationToken) =>
{
    var ownerId = ResolveOwnerId(user, null);
    var stock = await service.GetDipBookStockAsync(id, ownerId, date, cancellationToken);
    return Results.Ok(new { Stock = stock });
}).RequireAuthorization();

app.MapPost("/api/tanks", async (SaveTankRequest request, ITankCommandService service, CancellationToken cancellationToken) =>
{
    await service.SaveAsync(request, cancellationToken);
    return Results.Ok(new { Success = true });
}).RequireAuthorization();

app.MapGet("/api/parties", async (ClaimsPrincipal user, long? ownerId, long? pumpId, string? searchTerm, int? pageNumber, int? pageSize, IPartyQueryService service, CancellationToken cancellationToken) =>
{
    if (pumpId is null or <= 0)
    {
        return Results.BadRequest("pumpId is required.");
    }

    var resolvedOwnerId = ResolveOwnerId(user, ownerId);
    var pNum = pageNumber ?? 1;
    var pSize = pageSize ?? 10;
    var parties = await service.GetPagedListAsync(resolvedOwnerId, pumpId.Value, searchTerm, pNum, pSize, cancellationToken);
    return Results.Ok(parties);
}).RequireAuthorization();

app.MapGet("/api/parties/{id:long}", async (long id, ClaimsPrincipal user, long? ownerId, long? pumpId, IPartyQueryService service, CancellationToken cancellationToken) =>
{
    if (pumpId is null or <= 0)
    {
        return Results.BadRequest("pumpId is required.");
    }

    var resolvedOwnerId = ResolveOwnerId(user, ownerId);
    var party = await service.GetByIdAsync(id, resolvedOwnerId, pumpId.Value, cancellationToken);
    return party is null ? Results.NotFound() : Results.Ok(party);
}).RequireAuthorization();

app.MapPost("/api/parties", async (SavePartyRequest request, IPartyCommandService service, CancellationToken cancellationToken) =>
{
    await service.SaveAsync(request, cancellationToken);
    return Results.Ok(new { Success = true });
}).RequireAuthorization();

app.MapDelete("/api/parties/{id:long}", async (long id, ClaimsPrincipal user, long? ownerId, IPartyCommandService service, CancellationToken cancellationToken) =>
{
    var resolvedOwnerId = ResolveOwnerId(user, ownerId);
    try
    {
        await service.DeleteAsync(id, resolvedOwnerId, cancellationToken);
        return Results.Ok();
    }
    catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number is >= 50050 and <= 50059)
    {
        return Results.BadRequest(ex.Message);
    }
    catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number == 547)
    {
        return Results.BadRequest("Cannot delete: Party has linked data.");
    }
}).RequireAuthorization();

app.MapGet("/api/tank-transactions", async (ClaimsPrincipal user, long? ownerId, long pumpId, long? tankId, ITankTransactionService service, CancellationToken cancellationToken) =>
{
    var resolvedOwnerId = ResolveOwnerId(user, ownerId);
    var data = await service.GetByPumpAsync(resolvedOwnerId, pumpId, tankId, cancellationToken);
    return Results.Ok(data);
}).RequireAuthorization();

app.MapPost("/api/tank-transactions", async (SaveTankTransactionRequest request, ITankTransactionService service, CancellationToken cancellationToken) =>
{
    var id = await service.SaveAsync(request, cancellationToken);
    return Results.Ok(new { Id = id });
}).RequireAuthorization();

app.MapGet("/api/party-ledger", async (ClaimsPrincipal user, long? ownerId, long pumpId, long? partyId, IPartyLedgerService service, CancellationToken cancellationToken) =>
{
    var resolvedOwnerId = ResolveOwnerId(user, ownerId);
    var data = await service.GetByPumpAsync(resolvedOwnerId, pumpId, partyId, cancellationToken);
    return Results.Ok(data);
}).RequireAuthorization();

app.MapGet("/api/party-ledger/paged", async (ClaimsPrincipal user, long? ownerId, long pumpId, long? partyId, string? searchTerm, int? pageNumber, int? pageSize, IPartyLedgerService service, CancellationToken cancellationToken) =>
{
    var resolvedOwnerId = ResolveOwnerId(user, ownerId);
    var pNum = pageNumber ?? 1;
    var pSize = pageSize ?? 50;
    var data = await service.GetPagedListAsync(resolvedOwnerId, pumpId, partyId, searchTerm, pNum, pSize, cancellationToken);
    return Results.Ok(data);
}).RequireAuthorization();

// Ek party ka khaata (Section AF): purana baki + har line ke saath chalta hua baki.
// Purana baki khaate ki line nahi hai (wo Parties.OpeningBalance me hai), isliye
// /paged wali list se "itna baki kyun" ka jawab nahi milta tha.
app.MapGet("/api/party-ledger/statement", async (long pumpId, long partyId, string? searchTerm, int? pageNumber, int? pageSize, ClaimsPrincipal user, ITenantGuard guard, IPartyLedgerService service, CancellationToken cancellationToken) =>
{
    var ownerId = ResolveOwnerId(user, null);
    if (!await guard.OwnsAsync(ownerId, TenantEntities.Party, partyId, cancellationToken))
    {
        return Results.NotFound();
    }

    var data = await service.GetStatementAsync(ownerId, pumpId, partyId, searchTerm, pageNumber ?? 1, pageSize ?? 50, cancellationToken);
    return Results.Ok(data);
}).RequireAuthorization();

// Khaate ki haath se bani entry sudharna / hatana (Section AI). OwnerId JWT se; entry kis owner
// ki hai ye SP khud dekhta hai (WHERE Id AND OwnerId AND PumpId — 50290). Collection / bill
// wali line SP mana kar deta hai (50291). Wajah zaroori (50294) — AuditLog me "kisne, kyun".
app.MapPut("/api/party-ledger/{id:long}", async (long id, UpdatePartyLedgerEntryRequest request, ClaimsPrincipal user, IPartyLedgerService service, CancellationToken cancellationToken) =>
{
    var ownerId = ResolveOwnerId(user, null);
    long? userId = long.TryParse(user.FindFirstValue(ClaimTypes.NameIdentifier), out var uid) ? uid : null;
    try
    {
        await service.UpdateAsync(id, ownerId, userId, request, cancellationToken);
        return Results.Ok(new { Success = true });
    }
    catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number == 50290)
    {
        return Results.NotFound(new { Message = ex.Message });
    }
    catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number is >= 50291 and <= 50294)
    {
        return Results.BadRequest(new { Message = ex.Message });
    }
}).RequireAuthorization();

app.MapDelete("/api/party-ledger/{id:long}", async (long id, long pumpId, string? reason, ClaimsPrincipal user, IPartyLedgerService service, CancellationToken cancellationToken) =>
{
    var ownerId = ResolveOwnerId(user, null);
    long? userId = long.TryParse(user.FindFirstValue(ClaimTypes.NameIdentifier), out var uid) ? uid : null;
    try
    {
        await service.DeleteAsync(id, ownerId, pumpId, userId, reason, cancellationToken);
        return Results.Ok(new { Success = true });
    }
    catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number == 50290)
    {
        return Results.NotFound(new { Message = ex.Message });
    }
    catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number is >= 50291 and <= 50294)
    {
        return Results.BadRequest(new { Message = ex.Message });
    }
}).RequireAuthorization();

app.MapPost("/api/party-ledger", async (SavePartyLedgerEntryRequest request, IPartyLedgerService service, CancellationToken cancellationToken) =>
{
    var id = await service.SaveAsync(request, cancellationToken);
    return Results.Ok(new { Id = id });
}).RequireAuthorization();

app.MapGet("/api/pumps", async (ClaimsPrincipal user, long? ownerId, IPumpQueryService service, CancellationToken cancellationToken) =>
{
    var resolvedOwnerId = ResolveOwnerId(user, ownerId);
    var pumps = await service.GetByOwnerIdAsync(resolvedOwnerId, cancellationToken);
    return Results.Ok(pumps);
}).RequireAuthorization();

app.MapGet("/api/vendors", async (ClaimsPrincipal user, long? ownerId, long pumpId, IVendorService service, CancellationToken cancellationToken) =>
{
    var resolvedOwnerId = ResolveOwnerId(user, ownerId);
    var items = await service.GetByPumpAsync(resolvedOwnerId, pumpId, cancellationToken);
    return Results.Ok(items);
}).RequireAuthorization();

app.MapPost("/api/vendors", async (SaveVendorRequest request, IVendorService service, CancellationToken cancellationToken) =>
{
    var id = await service.SaveAsync(request, cancellationToken);
    return Results.Ok(new { Id = id });
}).RequireAuthorization();

app.MapDelete("/api/vendors/{id:long}", async (long id, ClaimsPrincipal user, long? ownerId, IVendorService service, CancellationToken cancellationToken) =>
{
    var resolvedOwnerId = ResolveOwnerId(user, ownerId);
    try
    {
        await service.DeleteAsync(id, resolvedOwnerId, cancellationToken);
        return Results.Ok(new { Success = true });
    }
    catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number is >= 50070 and <= 50079)
    {
        return Results.BadRequest(ex.Message);
    }
}).RequireAuthorization();

app.MapGet("/api/purchase", async (ClaimsPrincipal user, long? ownerId, long pumpId, DateTime? fromDate, DateTime? toDate, string? searchTerm, int? pageNumber, int? pageSize, IPurchaseService service, CancellationToken cancellationToken) =>
{
    var resolvedOwnerId = ResolveOwnerId(user, ownerId);
    var pNum = pageNumber ?? 1;
    var pSize = pageSize ?? 50;
    var items = await service.GetPagedListAsync(resolvedOwnerId, pumpId, fromDate, toDate, searchTerm, pNum, pSize, cancellationToken);
    return Results.Ok(items);
}).RequireAuthorization();

app.MapGet("/api/purchase/{id:long}", async (ClaimsPrincipal user, long id, long? ownerId, IPurchaseService service, CancellationToken cancellationToken) =>
{
    var resolvedOwnerId = ResolveOwnerId(user, ownerId);
    var purchase = await service.GetByIdAsync(id, resolvedOwnerId, cancellationToken);
    return purchase is null ? Results.NotFound() : Results.Ok(purchase);
}).RequireAuthorization();

app.MapPost("/api/purchase", async (SavePurchaseRequest request, IPurchaseService service, CancellationToken cancellationToken) =>
{
    if (request.Items is null || request.Items.Count == 0)
    {
        return Results.BadRequest("At least one purchase item is required.");
    }

    try
    {
        var id = await service.SaveAsync(request, cancellationToken);
        return Results.Ok(new { Id = id });
    }
    catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number == 50120)
    {
        // "Galat tank" wali jaanch. Ye user ki galti hai, server ki nahi — isliye
        // 500 "An unexpected error occurred" nahi, 400 ke saath asli wajah.
        return Results.BadRequest(new { Success = false, Message = ex.Message });
    }
}).RequireAuthorization();

app.MapGet("/api/stock-reconciliation", async (ClaimsPrincipal user, long? ownerId, long pumpId, long? tankId, DateTime? fromDate, DateTime? toDate, string? searchTerm, int? pageNumber, int? pageSize, IStockReconciliationService service, CancellationToken cancellationToken) =>
{
    var resolvedOwnerId = ResolveOwnerId(user, ownerId);
    var pNum = pageNumber ?? 1;
    var pSize = pageSize ?? 50;
    var items = await service.GetPagedListAsync(resolvedOwnerId, pumpId, tankId, fromDate, toDate, searchTerm, pNum, pSize, cancellationToken);
    return Results.Ok(items);
}).RequireAuthorization();

app.MapPost("/api/stock-reconciliation", async (SaveStockReconciliationRequest request, IStockReconciliationService service, CancellationToken cancellationToken) =>
{
    var id = await service.SaveAsync(request, cancellationToken);
    return Results.Ok(new { Id = id });
}).RequireAuthorization();

app.MapGet("/api/expense-heads", async (ClaimsPrincipal user, long? ownerId, long pumpId, IExpenseHeadService service, CancellationToken cancellationToken) =>
{
    var resolvedOwnerId = ResolveOwnerId(user, ownerId);
    var items = await service.GetByPumpAsync(resolvedOwnerId, pumpId, cancellationToken);
    return Results.Ok(items);
}).RequireAuthorization();

app.MapPost("/api/expense-heads", async (SaveExpenseHeadRequest request, IExpenseHeadService service, CancellationToken cancellationToken) =>
{
    var id = await service.SaveAsync(request, cancellationToken);
    return Results.Ok(new { Id = id });
}).RequireAuthorization();

app.MapDelete("/api/expense-heads/{id:long}", async (long id, ClaimsPrincipal user, long? ownerId, IExpenseHeadService service, CancellationToken cancellationToken) =>
{
    var resolvedOwnerId = ResolveOwnerId(user, ownerId);
    try
    {
        await service.DeleteAsync(id, resolvedOwnerId, cancellationToken);
        return Results.Ok(new { Success = true });
    }
    catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number is >= 50080 and <= 50089)
    {
        return Results.BadRequest(ex.Message);
    }
}).RequireAuthorization();

app.MapGet("/api/cash-transactions", async (ClaimsPrincipal user, long? ownerId, long pumpId, DateTime? fromDate, DateTime? toDate, string? searchTerm, int? pageNumber, int? pageSize, ICashTransactionService service, CancellationToken cancellationToken) =>
{
    var resolvedOwnerId = ResolveOwnerId(user, ownerId);
    var pNum = pageNumber ?? 1;
    var pSize = pageSize ?? 50;
    var items = await service.GetPagedListAsync(resolvedOwnerId, pumpId, fromDate, toDate, searchTerm, pNum, pSize, cancellationToken);
    return Results.Ok(items);
}).RequireAuthorization();

app.MapPost("/api/cash-transactions", async (SaveCashTransactionRequest request, ICashTransactionService service, CancellationToken cancellationToken) =>
{
    var id = await service.SaveAsync(request, cancellationToken);
    return Results.Ok(new { Id = id });
}).RequireAuthorization();

app.MapDelete("/api/cash-transactions/{id:long}", async (long id, ClaimsPrincipal user, long? ownerId, ICashTransactionService service, CancellationToken cancellationToken) =>
{
    var resolvedOwnerId = ResolveOwnerId(user, ownerId);
    try
    {
        await service.DeleteAsync(id, resolvedOwnerId, cancellationToken);
        return Results.Ok(new { Success = true });
    }
    catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number == 50013)
    {
        return Results.NotFound("Cash transaction not found or access denied.");
    }
}).RequireAuthorization();

app.MapGet("/api/expenses", async (ClaimsPrincipal user, long? ownerId, long pumpId, IExpenseService service, CancellationToken cancellationToken) =>
{
    var resolvedOwnerId = ResolveOwnerId(user, ownerId);
    var items = await service.GetByPumpAsync(resolvedOwnerId, pumpId, cancellationToken);
    return Results.Ok(items);
}).RequireAuthorization();

app.MapGet("/api/expenses/paged", async (ClaimsPrincipal user, long? ownerId, long pumpId, DateTime? fromDate, DateTime? toDate, string? searchTerm, int? pageNumber, int? pageSize, IExpenseService service, CancellationToken cancellationToken) =>
{
    var resolvedOwnerId = ResolveOwnerId(user, ownerId);
    var pNum = pageNumber ?? 1;
    var pSize = pageSize ?? 50;
    var items = await service.GetPagedByPumpAsync(resolvedOwnerId, pumpId, fromDate, toDate, searchTerm, pNum, pSize, cancellationToken);
    return Results.Ok(items);
}).RequireAuthorization();

app.MapPost("/api/expenses", async (SaveExpenseRequest request, IExpenseService service, CancellationToken cancellationToken) =>
{
    var id = await service.SaveAsync(request, cancellationToken);
    return Results.Ok(new { Id = id });
}).RequireAuthorization();

app.MapGet("/api/dip-readings", async (ClaimsPrincipal user, long? ownerId, long pumpId, DateTime? fromDate, DateTime? toDate, int? pageNumber, int? pageSize, IDipTestingService service, CancellationToken cancellationToken) =>
{
    var resolvedOwnerId = ResolveOwnerId(user, ownerId);
    var pNum = pageNumber ?? 1;
    var pSize = pageSize ?? 50;
    var items = await service.GetPagedDipReadingsAsync(resolvedOwnerId, pumpId, fromDate, toDate, pNum, pSize, cancellationToken);
    return Results.Ok(items);
}).RequireAuthorization();

app.MapPost("/api/dip-readings", async (ApiSaveDipReadingRequest request, IDipTestingService service, CancellationToken cancellationToken) =>
{
    var id = await service.SaveDipReadingAsync(request, cancellationToken);
    return Results.Ok(new { Id = id });
}).RequireAuthorization();

app.MapPut("/api/dip-readings/{id:long}", async (long id, ApiUpdateDipReadingRequest request, IDipTestingService service, CancellationToken cancellationToken) =>
{
    var success = await service.UpdateDipReadingAsync(id, request, cancellationToken);
    return success ? Results.Ok(new { Success = true }) : Results.NotFound();
}).RequireAuthorization();

app.MapPut("/api/dip-readings/{id:long}/toggle-active", async (long id, ClaimsPrincipal user, long? ownerId, long pumpId, IDipTestingService service, CancellationToken cancellationToken) =>
{
    var resolvedOwnerId = ResolveOwnerId(user, ownerId);
    var success = await service.ToggleDipReadingActiveAsync(id, resolvedOwnerId, pumpId, cancellationToken);
    return success ? Results.Ok(new { Success = true }) : Results.NotFound();
}).RequireAuthorization();

app.MapGet("/api/testing-losses", async (ClaimsPrincipal user, long? ownerId, long pumpId, DateTime? fromDate, DateTime? toDate, int? pageNumber, int? pageSize, IDipTestingService service, CancellationToken cancellationToken) =>
{
    var resolvedOwnerId = ResolveOwnerId(user, ownerId);
    var pNum = pageNumber ?? 1;
    var pSize = pageSize ?? 50;
    var items = await service.GetPagedTestingLossesAsync(resolvedOwnerId, pumpId, fromDate, toDate, pNum, pSize, cancellationToken);
    return Results.Ok(items);
}).RequireAuthorization();

app.MapPost("/api/testing-losses", async (ApiSaveTestingLossRequest request, IDipTestingService service, CancellationToken cancellationToken) =>
{
    var id = await service.SaveTestingLossAsync(request, cancellationToken);
    return Results.Ok(new { Id = id });
}).RequireAuthorization();

app.MapPut("/api/testing-losses/{id:long}", async (long id, ApiUpdateTestingLossRequest request, IDipTestingService service, CancellationToken cancellationToken) =>
{
    var success = await service.UpdateTestingLossAsync(id, request, cancellationToken);
    return success ? Results.Ok(new { Success = true }) : Results.NotFound();
}).RequireAuthorization();

app.MapPut("/api/testing-losses/{id:long}/toggle-active", async (long id, ClaimsPrincipal user, long? ownerId, long pumpId, IDipTestingService service, CancellationToken cancellationToken) =>
{
    var resolvedOwnerId = ResolveOwnerId(user, ownerId);
    var success = await service.ToggleTestingLossActiveAsync(id, resolvedOwnerId, pumpId, cancellationToken);
    return success ? Results.Ok(new { Success = true }) : Results.NotFound();
}).RequireAuthorization();

app.MapGet("/api/reports/day-book", async (ClaimsPrincipal user, long? ownerId, long pumpId, DateOnly dateFrom, DateOnly dateTo, IDayBookReportService service, CancellationToken cancellationToken) =>
{
    var resolvedOwnerId = ResolveOwnerId(user, ownerId);
    var items = await service.GetAsync(resolvedOwnerId, pumpId, dateFrom, dateTo, cancellationToken);
    return Results.Ok(items);
}).RequireAuthorization();

app.MapGet("/api/reports/outstanding", async (ClaimsPrincipal user, long? ownerId, long pumpId, IReportInsightsService service, CancellationToken cancellationToken) =>
{
    var resolvedOwnerId = ResolveOwnerId(user, ownerId);
    var items = await service.GetOutstandingAsync(resolvedOwnerId, pumpId, cancellationToken);
    return Results.Ok(items);
}).RequireAuthorization();

app.MapGet("/api/reports/pump-comparison", async (ClaimsPrincipal user, long? ownerId, DateOnly dateFrom, DateOnly dateTo, IReportInsightsService service, CancellationToken cancellationToken) =>
{
    var resolvedOwnerId = ResolveOwnerId(user, ownerId);
    var items = await service.GetPumpComparisonAsync(resolvedOwnerId, dateFrom, dateTo, cancellationToken);
    return Results.Ok(items);
}).RequireAuthorization();

// Is report me OwnerId tha hi nahi — na endpoint me, na sp_Report_DailyStockRegister me.
// Sirf pumpId guess karke doosre owner ki poore mahine ki stock report nikaali ja sakti thi.
app.MapGet("/api/reports/daily-stock-register", async (long pumpId, long productId, int month, int year, ClaimsPrincipal user, ITenantGuard guard, IReportInsightsService service, CancellationToken cancellationToken) =>
{
    var ownerId = ResolveOwnerId(user, null);
    if (!await guard.OwnsAsync(ownerId, TenantEntities.Pump, pumpId, cancellationToken))
    {
        return Results.NotFound();
    }

    var items = await service.GetDailyStockRegisterAsync(pumpId, productId, month, year, cancellationToken);
    return Results.Ok(items);
}).RequireAuthorization();

// Maahwar bikri-khareed register (Section AD) - owner ke haath wale rajistar jaisa.
app.MapGet("/api/reports/sale-purchase-register", async (long pumpId, long productId, int month, int year, ClaimsPrincipal user, ITenantGuard guard, IReportInsightsService service, CancellationToken cancellationToken) =>
{
    var ownerId = ResolveOwnerId(user, null);
    if (!await guard.OwnsAsync(ownerId, TenantEntities.Pump, pumpId, cancellationToken))
    {
        return Results.NotFound();
    }

    var items = await service.GetMonthlySaleRegisterAsync(pumpId, productId, month, year, ownerId, cancellationToken);
    return Results.Ok(items);
}).RequireAuthorization();

// Munafa (P&L) - Section AO1. Owner hamesha claim se; pump usi owner ka ho.
app.MapGet("/api/reports/profit-loss", async (long pumpId, DateOnly dateFrom, DateOnly dateTo, ClaimsPrincipal user, ITenantGuard guard, IReportInsightsService service, CancellationToken cancellationToken) =>
{
    var ownerId = ResolveOwnerId(user, null);
    if (!await guard.OwnsAsync(ownerId, TenantEntities.Pump, pumpId, cancellationToken))
    {
        return Results.NotFound();
    }

    var items = await service.GetProfitLossAsync(ownerId, pumpId, dateFrom, dateTo, cancellationToken);
    return Results.Ok(items);
}).RequireAuthorization();

// Financials - Section AP. Paisa kahan hai: stock, udhaar, galla, aur chuni tareekh ka len-den.
app.MapGet("/api/reports/financials", async (long pumpId, DateOnly dateFrom, DateOnly dateTo, ClaimsPrincipal user, ITenantGuard guard, IReportInsightsService service, CancellationToken cancellationToken) =>
{
    var ownerId = ResolveOwnerId(user, null);
    if (!await guard.OwnsAsync(ownerId, TenantEntities.Pump, pumpId, cancellationToken))
    {
        return Results.NotFound();
    }

    var items = await service.GetFinancialsAsync(ownerId, pumpId, dateFrom, dateTo, cancellationToken);
    return Results.Ok(items);
}).RequireAuthorization();

// Activity Log - Section AO2. Sirf apne owner ka AuditLog.
app.MapGet("/api/activity-log", async (DateOnly dateFrom, DateOnly dateTo, string? area, int? pageNumber, int? pageSize, ClaimsPrincipal user, IReportInsightsService service, CancellationToken cancellationToken) =>
{
    var ownerId = ResolveOwnerId(user, null);
    var size = Math.Clamp(pageSize ?? 100, 1, 500);
    var items = await service.GetActivityLogAsync(ownerId, dateFrom, dateTo, area, Math.Max(1, pageNumber ?? 1), size, cancellationToken);
    return Results.Ok(items);
}).RequireAuthorization();

app.MapGet("/api/fleet-contracts", async (ClaimsPrincipal user, long? ownerId, long pumpId, IFleetCouponService service, CancellationToken cancellationToken) =>
{
    var resolvedOwnerId = ResolveOwnerId(user, ownerId);
    var items = await service.GetFleetContractsAsync(resolvedOwnerId, pumpId, cancellationToken);
    return Results.Ok(items);
}).RequireAuthorization();

app.MapPost("/api/fleet-contracts", async (SaveFleetContractRequest request, IFleetCouponService service, CancellationToken cancellationToken) =>
{
    var id = await service.SaveFleetContractAsync(request, cancellationToken);
    return Results.Ok(new { Id = id });
}).RequireAuthorization();

app.MapGet("/api/coupon-books", async (ClaimsPrincipal user, long? ownerId, long pumpId, IFleetCouponService service, CancellationToken cancellationToken) =>
{
    var resolvedOwnerId = ResolveOwnerId(user, ownerId);
    var items = await service.GetCouponBooksAsync(resolvedOwnerId, pumpId, cancellationToken);
    return Results.Ok(items);
}).RequireAuthorization();

app.MapPost("/api/coupon-books", async (SaveCouponBookRequest request, IFleetCouponService service, CancellationToken cancellationToken) =>
{
    var id = await service.SaveCouponBookAsync(request, cancellationToken);
    return Results.Ok(new { Id = id });
}).RequireAuthorization();

app.MapGet("/api/coupon-transactions", async (ClaimsPrincipal user, long? ownerId, long pumpId, long? couponBookId, IFleetCouponService service, CancellationToken cancellationToken) =>
{
    var resolvedOwnerId = ResolveOwnerId(user, ownerId);
    var items = await service.GetCouponTransactionsAsync(resolvedOwnerId, pumpId, couponBookId, cancellationToken);
    return Results.Ok(items);
}).RequireAuthorization();

app.MapPost("/api/coupon-transactions", async (SaveCouponTransactionRequest request, IFleetCouponService service, CancellationToken cancellationToken) =>
{
    var id = await service.SaveCouponTransactionAsync(request, cancellationToken);
    return Results.Ok(new { Id = id });
}).RequireAuthorization();

app.MapPost("/api/pumps", async (SavePumpRequest request, IPumpCommandService service, CancellationToken cancellationToken) =>
{
    var id = await service.SaveAsync(request, cancellationToken);
    return Results.Ok(new { Id = id });
}).RequireAuthorization();

app.MapDelete("/api/pumps/{id:long}", async (long id, ClaimsPrincipal user, long? ownerId, IPumpCommandService service, CancellationToken cancellationToken) =>
{
    var resolvedOwnerId = ResolveOwnerId(user, ownerId);
    try
    {
        await service.DeleteAsync(id, resolvedOwnerId, cancellationToken);
        return Results.Ok();
    }
    catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number is >= 50100 and <= 50109)
    {
        return Results.BadRequest(ex.Message);
    }
    catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number == 547)
    {
        return Results.BadRequest("Cannot delete this pump because it has related data.");
    }
}).RequireAuthorization();


app.MapDelete("/api/tanks/{id:long}", async (long id, ClaimsPrincipal user, long? ownerId, ITankCommandService service, CancellationToken cancellationToken) =>
{
    var resolvedOwnerId = ResolveOwnerId(user, ownerId);
    try
    {
        await service.DeleteAsync(id, resolvedOwnerId, cancellationToken);
        return Results.Ok();
    }
    catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number is >= 50030 and <= 50039)
    {
        return Results.BadRequest(ex.Message);
    }
    catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number == 547)
    {
        return Results.BadRequest("Cannot delete this tank because it is linked to transactions or stock.");
    }
}).RequireAuthorization();

app.MapGet("/api/nozzles", async (ClaimsPrincipal user, long? ownerId, long? pumpId, INozzleQueryService service, CancellationToken cancellationToken) =>
{
    var resolvedOwnerId = ResolveOwnerId(user, ownerId);
    var nozzles = await service.GetByPumpAsync(resolvedOwnerId, pumpId, cancellationToken);
    return Results.Ok(nozzles);
}).RequireAuthorization();

app.MapPost("/api/nozzles", async (SaveNozzleRequest request, INozzleCommandService service, CancellationToken cancellationToken) =>
{
    try
    {
        var id = await service.SaveAsync(request, cancellationToken);
        return Results.Ok(new { Id = id });
    }
    catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number == 50062)
    {
        // Chuna gaya tank is pump/product ka nahi hai. Multi-pump me ye aam galti
        // hai — saaf message chahiye, "unexpected error" nahi.
        return Results.BadRequest(new { Success = false, Message = ex.Message });
    }
}).RequireAuthorization();

app.MapDelete("/api/nozzles/{id:long}", async (long id, ClaimsPrincipal user, long? ownerId, INozzleCommandService service, CancellationToken cancellationToken) =>
{
    var resolvedOwnerId = ResolveOwnerId(user, ownerId);
    try
    {
        await service.DeleteAsync(id, resolvedOwnerId, cancellationToken);
        return Results.Ok();
    }
    catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number is >= 50020 and <= 50029)
    {
        return Results.BadRequest(ex.Message);
    }
    catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number == 547)
    {
        return Results.BadRequest("Cannot delete this nozzle because it is linked to sales or meter readings.");
    }
}).RequireAuthorization();

app.MapGet("/api/users", async (ClaimsPrincipal user, long? ownerId, IUserService service, CancellationToken cancellationToken) =>
{
    var resolvedOwnerId = ResolveOwnerId(user, ownerId);
    var users = await service.GetAllAsync(resolvedOwnerId, cancellationToken);
    return Results.Ok(users);
}).RequireAuthorization();

app.MapPost("/api/users", async (SaveUserRequest request, IUserService service, CancellationToken cancellationToken) =>
{
    var id = await service.SaveAsync(request, cancellationToken);
    return Results.Ok(new { Id = id });
}).RequireAuthorization();

app.MapDelete("/api/users/{id:long}", async (long id, ClaimsPrincipal user, long? ownerId, IUserService service, CancellationToken cancellationToken) =>
{
    var resolvedOwnerId = ResolveOwnerId(user, ownerId);
    try
    {
        await service.DeleteAsync(id, resolvedOwnerId, cancellationToken);
        return Results.Ok();
    }
    catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number is >= 50060 and <= 50069)
    {
        return Results.BadRequest(ex.Message);
    }
    catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number == 547)
    {
        return Results.BadRequest("Cannot delete this user because they are linked to shifts, expenses, or transactions.");
    }
}).RequireAuthorization();

// ---- Staff: employee + (chaahein to) uska login, ek hi call me ----------------
// Pehle ye do alag page the — /api/users par login, /api/employees par HR record —
// aur naam-mobile dono jagah alag-alag bharna padta tha. Ab ek save me dono.
// Tables waise ke waise hain; sirf save ek jagah se hota hai (sp_Staff_Save).
app.MapGet("/api/staff", async (ClaimsPrincipal user, long? ownerId, long pumpId, PPMS.Application.Features.Staff.IStaffService service, CancellationToken cancellationToken) =>
{
    var resolvedOwnerId = ResolveOwnerId(user, ownerId);
    var items = await service.GetByPumpAsync(resolvedOwnerId, pumpId, cancellationToken);
    return Results.Ok(items);
}).RequireAuthorization();

app.MapPost("/api/staff", async (PPMS.Application.Features.Staff.SaveStaffRequest request, ClaimsPrincipal user, PPMS.Application.Features.Staff.IStaffService service, CancellationToken cancellationToken) =>
{
    // OwnerId hamesha JWT se — body me jo aaya hai use bharosa nahi.
    var safeRequest = request with { OwnerId = ResolveOwnerId(user, null) };
    try
    {
        var result = await service.SaveAsync(safeRequest, cancellationToken);
        return Results.Ok(result);
    }
    catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number is >= 50150 and <= 50179)
    {
        // Hamare apne saaf-saaf message (galat pump, username pehle se hai, waghairah)
        return Results.BadRequest(ex.Message);
    }
    catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number is 2627 or 2601)
    {
        return Results.BadRequest("Employee code or username already exists.");
    }
    catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number == 547)
    {
        return Results.BadRequest("Invalid reference selected. Please check the pump and role.");
    }
}).RequireAuthorization();

// ================= Message credits =================
// Do khaate: platform (aapka stock, Twilio se khareeda) aur wallet (har owner ka).
// Sab owner ko mila kar becha hua stock se zyada nahi ho sakta — wo jaanch
// sp_Wallet_ApproveRecharge ke andar lock ke saath hoti hai.

// ---- superadmin ----
app.MapGet("/api/platform-credit", async (ICreditRepository repo, CancellationToken cancellationToken) =>
{
    var summary = await repo.GetPlatformSummaryAsync(cancellationToken);
    return Results.Ok(summary);
}).RequireAuthorization("SuperAdminOnly");

app.MapPost("/api/platform-credit", async (AddPlatformCreditRequest request, ClaimsPrincipal user, ICreditRepository repo, CancellationToken cancellationToken) =>
{
    long? userId = long.TryParse(user.FindFirstValue(ClaimTypes.NameIdentifier), out var uid) ? uid : null;
    var summary = await repo.AddPlatformCreditAsync(request, userId, cancellationToken);
    return Results.Ok(summary);
}).RequireAuthorization("SuperAdminOnly");

app.MapPost("/api/platform-credit/settings", async (SaveCreditSettingsRequest request, ICreditRepository repo, CancellationToken cancellationToken) =>
{
    var settings = await repo.SaveSettingsAsync(request.UpiId, request.UpiName, request.PricePerCredit, cancellationToken);
    return Results.Ok(settings);
}).RequireAuthorization("SuperAdminOnly");

// Support ke number (Section AR). Padhna bina login - login page ko chahiye.
app.MapGet("/api/support-contacts", async (ISupportContactRepository repo, CancellationToken cancellationToken) =>
    Results.Ok(await repo.GetAsync(cancellationToken)));

app.MapPost("/api/support-contacts", async (SaveSupportContactsRequest request, ClaimsPrincipal user, ISupportContactRepository repo, CancellationToken cancellationToken) =>
{
    // Sirf ank. "+91 98765-43210" / "098765..." -> 10 ank ka mobile; landline 11-13 ank tak.
    static string? Clean(string? v)
    {
        if (string.IsNullOrWhiteSpace(v)) return null;
        var digits = new string(v.Where(char.IsDigit).ToArray());
        if (digits.Length == 12 && digits.StartsWith("91")) digits = digits[2..];
        else if (digits.Length == 11 && digits.StartsWith('0')) digits = digits[1..];
        return digits.Length == 0 ? null : digits;
    }
    var phones = new[] { Clean(request.Phone1), Clean(request.Phone2), Clean(request.Phone3) };
    if (phones[0] is null)
        return Results.BadRequest(new { Success = false, Message = "The first support number is required." });
    if (phones.Any(p => p is not null && (p.Length < 10 || p.Length > 13)))
        return Results.BadRequest(new { Success = false, Message = "Each support number must have 10 to 13 digits." });

    long? userId = long.TryParse(user.FindFirstValue(ClaimTypes.NameIdentifier), out var uid) ? uid : null;
    return Results.Ok(await repo.SaveAsync(phones[0]!, phones[1], phones[2], userId, cancellationToken));
}).RequireAuthorization("SuperAdminOnly");

app.MapGet("/api/platform-credit/recharges", async (string? status, ICreditRepository repo, CancellationToken cancellationToken) =>
{
    // ownerId NULL = sabki list. Ye sirf superadmin ke liye hai.
    var items = await repo.ListRechargesAsync(null, status, cancellationToken);
    return Results.Ok(items);
}).RequireAuthorization("SuperAdminOnly");

app.MapPost("/api/platform-credit/recharges/{id:long}/approve", async (long id, DecideRechargeRequest request, ClaimsPrincipal user, ICreditRepository repo, CancellationToken cancellationToken) =>
{
    long? userId = long.TryParse(user.FindFirstValue(ClaimTypes.NameIdentifier), out var uid) ? uid : null;
    var result = await repo.ApproveRechargeAsync(id, userId, request.Note, cancellationToken);
    return Results.Ok(result);
}).RequireAuthorization("SuperAdminOnly");

app.MapPost("/api/platform-credit/recharges/{id:long}/reject", async (long id, DecideRechargeRequest request, ClaimsPrincipal user, ICreditRepository repo, CancellationToken cancellationToken) =>
{
    long? userId = long.TryParse(user.FindFirstValue(ClaimTypes.NameIdentifier), out var uid) ? uid : null;
    await repo.RejectRechargeAsync(id, userId, request.Note, cancellationToken);
    return Results.Ok(new { Success = true });
}).RequireAuthorization("SuperAdminOnly");

// ---- owner ka apna wallet ----
// OwnerId hamesha JWT se — isliye ek owner doosre ka wallet na dekh sakta hai
// na uska recharge maang sakta hai.
app.MapGet("/api/wallet", async (ClaimsPrincipal user, ICreditRepository repo, CancellationToken cancellationToken) =>
{
    var ownerId = ResolveOwnerId(user, null);
    var wallet = await repo.GetWalletAsync(ownerId, cancellationToken);
    return Results.Ok(wallet);
}).RequireAuthorization();

app.MapGet("/api/wallet/ledger", async (ClaimsPrincipal user, int? top, ICreditRepository repo, CancellationToken cancellationToken) =>
{
    var ownerId = ResolveOwnerId(user, null);
    var rows = await repo.GetLedgerAsync(ownerId, top is > 0 and <= 200 ? top.Value : 50, cancellationToken);
    return Results.Ok(rows);
}).RequireAuthorization();

app.MapGet("/api/wallet/recharges", async (ClaimsPrincipal user, ICreditRepository repo, CancellationToken cancellationToken) =>
{
    var ownerId = ResolveOwnerId(user, null);
    var items = await repo.ListRechargesAsync(ownerId, null, cancellationToken);
    return Results.Ok(items);
}).RequireAuthorization();

app.MapPost("/api/wallet/recharge", async (RequestRechargeInput request, ClaimsPrincipal user, ICreditRepository repo, CancellationToken cancellationToken) =>
{
    var ownerId = ResolveOwnerId(user, null);
    var result = await repo.RequestRechargeAsync(ownerId, request.Amount, request.UpiReference, cancellationToken);
    return Results.Ok(result);
}).RequireAuthorization();

// ---- Owner alerts: kaunse sandesh chahiye, aur kis number par ----------------
// OwnerId hamesha JWT se — body ya query se kabhi nahi. Isliye ek owner doosre ki
// settings na dekh sakta hai na badal sakta hai.
app.MapGet("/api/owner-alerts", async (ClaimsPrincipal user, IOwnerAlertRepository repo, CancellationToken cancellationToken) =>
{
    var ownerId = ResolveOwnerId(user, null);
    var items = await repo.ListAsync(ownerId, cancellationToken);

    // Screen par wahi number dikhana hai jispar alert SACH ME jayenge — yaani
    // Owners.ContactNo, aur wo khaali ho to owner-user ka mobile (wahi fallback
    // jo sp_Notification_GetOwnerTarget lagata hai). Isliye number bhi wahin se
    // le rahe hain, alag query se nahi.
    var target = await repo.GetTargetAsync(ownerId, "SHIFT_CLOSE", cancellationToken);

    return Results.Ok(new { Mobile = target?.Mobile, Alerts = items });
}).RequireAuthorization();

app.MapPost("/api/owner-alerts", async (SaveOwnerAlertRequest request, ClaimsPrincipal user, IOwnerAlertRepository repo, CancellationToken cancellationToken) =>
{
    var ownerId = ResolveOwnerId(user, null);
    await repo.SaveAsync(ownerId, request.AlertKey, request.IsEnabled, cancellationToken);
    return Results.Ok(new { Success = true });
}).RequireAuthorization();

app.MapPost("/api/owner-alerts/mobile", async (SaveOwnerAlertMobileRequest request, ClaimsPrincipal user, IOwnerAlertRepository repo, CancellationToken cancellationToken) =>
{
    var ownerId = ResolveOwnerId(user, null);
    await repo.SaveMobileAsync(ownerId, request.Mobile, cancellationToken);
    return Results.Ok(new { Success = true });
}).RequireAuthorization();

app.MapGet("/api/employees", async (ClaimsPrincipal user, long? ownerId, long pumpId, IEmployeeService service, CancellationToken cancellationToken) =>
{
    var resolvedOwnerId = ResolveOwnerId(user, ownerId);
    var items = await service.GetByPumpAsync(resolvedOwnerId, pumpId, cancellationToken);
    return Results.Ok(items);
}).RequireAuthorization();

app.MapPost("/api/employees", async (SaveEmployeeRequest request, IEmployeeService service, CancellationToken cancellationToken) =>
{
    try
    {
        var id = await service.SaveAsync(request, cancellationToken);
        return Results.Ok(new { Id = id });
    }
    catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number == 2627 || ex.Number == 2601)
    {
        return Results.BadRequest("Employee code already exists for this pump.");
    }
    catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number == 547)
    {
        return Results.BadRequest("Invalid reference selected. Please check pump/user mapping.");
    }
    catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number == 2812)
    {
        return Results.BadRequest("Employee setup stored procedure is missing. Run 014_sp_employee_salary.sql.");
    }
    catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number == 208)
    {
        return Results.BadRequest("Employee setup table is missing. Run 014_tables_employee_salary.sql.");
    }
}).RequireAuthorization();

app.MapDelete("/api/employees/{id:long}", async (long id, ClaimsPrincipal user, long? ownerId, IEmployeeService service, CancellationToken cancellationToken) =>
{
    var resolvedOwnerId = ResolveOwnerId(user, ownerId);
    try
    {
        await service.DeleteAsync(id, resolvedOwnerId, cancellationToken);
        return Results.Ok(new { Success = true });
    }
    catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number is >= 50090 and <= 50099)
    {
        return Results.BadRequest(ex.Message);
    }
}).RequireAuthorization();

app.MapGet("/api/salary-payments", async (ClaimsPrincipal user, long? ownerId, long pumpId, int? salaryYear, int? salaryMonth, ISalaryPaymentService service, CancellationToken cancellationToken) =>
{
    var resolvedOwnerId = ResolveOwnerId(user, ownerId);
    var items = await service.GetByPumpAsync(resolvedOwnerId, pumpId, salaryYear, salaryMonth, cancellationToken);
    return Results.Ok(items);
}).RequireAuthorization();

app.MapPost("/api/salary-payments", async (SaveSalaryPaymentRequest request, ISalaryPaymentService service, CancellationToken cancellationToken) =>
{
    try
    {
        var id = await service.SaveAsync(request, cancellationToken);
        return Results.Ok(new { Id = id });
    }
    catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number == 2627 || ex.Number == 2601)
    {
        return Results.BadRequest("Salary for this employee and month already exists.");
    }
    catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number == 547)
    {
        return Results.BadRequest("Invalid employee selected for salary payment.");
    }
    catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number == 2812)
    {
        return Results.BadRequest("Salary setup stored procedure is missing. Run 014_sp_employee_salary.sql.");
    }
    catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number == 208)
    {
        return Results.BadRequest("Salary setup table is missing. Run 014_tables_employee_salary.sql.");
    }
}).RequireAuthorization();

// Karmchari ka advance aur mahine ki salary ka hisaab (Section AQ). Owner JWT se; pump usi owner ka.
app.MapGet("/api/salary-summary", async (long pumpId, int year, int month, ClaimsPrincipal user, ITenantGuard guard, ISalaryPaymentService service, CancellationToken cancellationToken) =>
{
    var ownerId = ResolveOwnerId(user, null);
    if (!await guard.OwnsAsync(ownerId, TenantEntities.Pump, pumpId, cancellationToken)) return Results.NotFound();
    return Results.Ok(await service.GetSummaryAsync(ownerId, pumpId, year, month, cancellationToken));
}).RequireAuthorization();

app.MapGet("/api/employee-advances", async (long pumpId, ClaimsPrincipal user, ITenantGuard guard, ISalaryPaymentService service, CancellationToken cancellationToken) =>
{
    var ownerId = ResolveOwnerId(user, null);
    if (!await guard.OwnsAsync(ownerId, TenantEntities.Pump, pumpId, cancellationToken)) return Results.NotFound();
    return Results.Ok(await service.GetAdvancesAsync(ownerId, pumpId, cancellationToken));
}).RequireAuthorization();

app.MapPost("/api/employee-advances", async (SaveEmployeeAdvanceRequest request, ClaimsPrincipal user, ITenantGuard guard, ISalaryPaymentService service, CancellationToken cancellationToken) =>
{
    var ownerId = ResolveOwnerId(user, null);
    if (!await guard.OwnsAsync(ownerId, TenantEntities.Pump, request.PumpId, cancellationToken)) return Results.NotFound();
    long? userId = long.TryParse(user.FindFirstValue(ClaimTypes.NameIdentifier), out var advUid) ? advUid : null;
    var id = await service.SaveAdvanceAsync(request, ownerId, userId, cancellationToken);
    return Results.Ok(new { Id = id });
}).RequireAuthorization();

app.MapDelete("/api/employee-advances/{id:long}", async (long id, ClaimsPrincipal user, ISalaryPaymentService service, CancellationToken cancellationToken) =>
{
    var ownerId = ResolveOwnerId(user, null);
    long? userId = long.TryParse(user.FindFirstValue(ClaimTypes.NameIdentifier), out var advUid) ? advUid : null;
    await service.DeleteAdvanceAsync(id, ownerId, userId, cancellationToken);
    return Results.Ok(new { Success = true });
}).RequireAuthorization();

app.MapGet("/api/roles", async (ClaimsPrincipal user, long? ownerId, IRoleService service, CancellationToken cancellationToken) =>
{
    var resolvedOwnerId = ResolveOwnerId(user, ownerId);
    var roles = await service.GetAllAsync(resolvedOwnerId, cancellationToken);
    return Results.Ok(roles);
}).RequireAuthorization();

app.MapPost("/api/roles", async (SaveRoleRequest request, IRoleService service, CancellationToken cancellationToken) =>
{
    var id = await service.SaveAsync(request, cancellationToken);
    return Results.Ok(new { Id = id });
}).RequireAuthorization();

app.MapGet("/api/roles/{id:long}/menus", async (long id, ClaimsPrincipal user, ITenantGuard guard, IRoleService service, CancellationToken cancellationToken) =>
{
    var ownerId = ResolveOwnerId(user, null);
    if (!await guard.OwnsAsync(ownerId, TenantEntities.Role, id, cancellationToken))
    {
        return Results.NotFound();
    }

    var roleMenus = await service.GetRoleMenusAsync(id, cancellationToken);
    return Results.Ok(roleMenus);
}).RequireAuthorization();

app.MapPost("/api/roles/menus", async (SaveRoleMenusRequest request, IRoleService service, CancellationToken cancellationToken) =>
{
    await service.SaveRoleMenusAsync(request, cancellationToken);
    return Results.Ok(new { Success = true });
}).RequireAuthorization();

app.MapGet("/api/shifts", async (ClaimsPrincipal user, long? ownerId, long? pumpId, IShiftService service, CancellationToken cancellationToken) =>
{
    var resolvedOwnerId = ResolveOwnerId(user, ownerId);
    var shifts = await service.GetAllAsync(resolvedOwnerId, pumpId, cancellationToken);
    return Results.Ok(shifts);
}).RequireAuthorization();

app.MapGet("/api/shifts/paged", async (ClaimsPrincipal user, long? ownerId, long? pumpId, DateTime? fromDate, DateTime? toDate, string? searchTerm, int? pageNumber, int? pageSize, IShiftService service, CancellationToken cancellationToken) =>
{
    var resolvedOwnerId = ResolveOwnerId(user, ownerId);
    var pNum = pageNumber ?? 1;
    var pSize = pageSize ?? 50;
    var shifts = await service.GetPagedListAsync(resolvedOwnerId, pumpId, fromDate, toDate, searchTerm, pNum, pSize, cancellationToken);
    return Results.Ok(shifts);
}).RequireAuthorization();

app.MapPost("/api/shifts/open", async (OpenShiftRequest request, IShiftService service, CancellationToken cancellationToken) =>
{
    try
    {
        var id = await service.OpenAsync(request, cancellationToken);
        if (id <= 0)
        {
            return Results.Conflict("Another shift is already open for this pump. Close it first.");
        }

        return Results.Ok(new { Id = id });
    }
    catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number is 50003 or 50130 or 50132)
    {
        // 50132 = meter ki kadi nahi jud rahi (Section R).
        // Nozzle ka tank set nahi, ya ek bhi nozzle nahi juda (multi-pump me galat
        // pump ka nozzle). User ki galti hai — 500 nahi, asli wajah ke saath 400.
        return Results.BadRequest(new { Success = false, Message = ex.Message });
    }
}).RequireAuthorization();

// Din ka collection — Online / Card / udhaar (Section W).
// Shift kis owner ki hai, ye guard jaanchta hai; OwnerId JWT se aata hai.
app.MapGet("/api/shifts/{id:long}/collection", async (long id, ClaimsPrincipal user, ITenantGuard guard, IShiftService service, CancellationToken cancellationToken) =>
{
    var ownerId = ResolveOwnerId(user, null);
    if (ownerId <= 0) return Results.Unauthorized();
    if (!await guard.OwnsAsync(ownerId, TenantEntities.Shift, id, cancellationToken)) return Results.NotFound();

    var data = await service.GetCollectionAsync(id, ownerId, cancellationToken);
    return Results.Ok(data);
}).RequireAuthorization();

app.MapPost("/api/shifts/{id:long}/collection", async (long id, SaveShiftCollectionRequest request, ClaimsPrincipal user, ITenantGuard guard, IShiftService service, CancellationToken cancellationToken) =>
{
    if (id != request.ShiftId) return Results.BadRequest("Id mismatch");

    var ownerId = ResolveOwnerId(user, null);
    if (ownerId <= 0) return Results.Unauthorized();
    if (!await guard.OwnsAsync(ownerId, TenantEntities.Shift, id, cancellationToken)) return Results.NotFound();

    long? userId = long.TryParse(user.FindFirstValue(ClaimTypes.NameIdentifier), out var collUid) ? collUid : null;
    await service.SaveCollectionAsync(request, ownerId, userId, cancellationToken);
    return Results.Ok(new { Success = true });
}).RequireAuthorization();

// Ek jaisi udhaar ki jaanch (Section AQ4) - sirf batata hai, rokta nahi. Shift / party usi owner ki
// hai ye SP OwnerId se khud chhaanta hai; doosre owner ki shift di to din hi nahi milta.
app.MapPost("/api/credit/duplicates", async (CreditDuplicateCheckRequest request, ClaimsPrincipal user, IShiftService service, CancellationToken cancellationToken) =>
{
    var ownerId = ResolveOwnerId(user, null);
    if (ownerId <= 0) return Results.Unauthorized();
    var items = await service.FindCreditDuplicatesAsync(request, ownerId, cancellationToken);
    return Results.Ok(items);
}).RequireAuthorization();

// Meter ki tooti hui kadi (Section R2) — sirf batata hai, rokta kuch nahi.
// OwnerId hamesha JWT se; client jo bheje uspar bharosa nahi.
app.MapGet("/api/shifts/meter-chain", async (ClaimsPrincipal user, long? pumpId, int? days, IShiftService service, CancellationToken cancellationToken) =>
{
    var ownerId = ResolveOwnerId(user, null);
    if (ownerId <= 0) return Results.Unauthorized();

    var window = days is > 0 and <= 730 ? days.Value : 90;
    var gaps = await service.GetMeterChainGapsAsync(ownerId, pumpId, window, cancellationToken);
    return Results.Ok(gaps);
}).RequireAuthorization();

// Yahan pehle KOI TENANT GUARD NAHI THA. CloseShiftRequest me OwnerId hai hi nahi,
// isliye TenantIsolationMiddleware ke paas saaf karne ko kuch tha hi nahi — aur
// sp_Shift_Close OwnerId khud shift se utha leta hai, caller se poochta nahi.
// Nateeja: kisi bhi tenant ka logged-in user shift ki id jaan kar DOOSRE tenant ki
// shift band kar sakta tha (aur uska poora cash hisaab bigaad sakta tha).
// Baaki shift endpoints par guard pehle se tha; ye do chhoot gaye the.
app.MapPost("/api/shifts/{id:long}/close", async (long id, CloseShiftRequest request, ClaimsPrincipal user, ITenantGuard guard, IShiftService service, CancellationToken cancellationToken) =>
{
    if (id != request.Id) return Results.BadRequest("Id mismatch");

    var ownerId = ResolveOwnerId(user, null);
    if (!await guard.OwnsAsync(ownerId, TenantEntities.Shift, id, cancellationToken))
    {
        return Results.NotFound();
    }

    try
    {
        var shiftId = await service.CloseAsync(request, ownerId, cancellationToken);
        if (shiftId == -2)
        {
            return Results.Conflict("Shift is already closed.");
        }

        return Results.Ok(new { Id = shiftId });
    }
    catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number == 50001)
    {
        return Results.BadRequest("Closing reading cannot be less than opening reading.");
    }
    catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number == 50002)
    {
        return Results.BadRequest("All assigned nozzles must have closing reading before shift close.");
    }
    catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number == 50003)
    {
        return Results.BadRequest("Tank mapping missing for one or more sold products. Configure tank-product mapping first.");
    }
}).RequireAuthorization();

// ── Close Shift form me hi tank ki dip (Section AB) ─────────────────────────
// Pehle dip alag page par jaati thi, aur wahin galti hoti thi: shift band hone se
// pehle dip (book stock me us din ki bikri ghati hi nahi hoti), galat tareekh.
// Ab shift band hote hi usi form se — tareekh aur shift apne aap wahi.
app.MapGet("/api/shifts/{id:long}/closing-dips", async (long id, ClaimsPrincipal user, ITenantGuard guard, IShiftService service, CancellationToken cancellationToken) =>
{
    var ownerId = ResolveOwnerId(user, null);
    if (!await guard.OwnsAsync(ownerId, TenantEntities.Shift, id, cancellationToken))
    {
        return Results.NotFound();
    }

    var rows = await service.GetClosingDipsAsync(id, ownerId, cancellationToken);
    return Results.Ok(rows);
}).RequireAuthorization();

app.MapPost("/api/shifts/{id:long}/closing-dips", async (long id, SaveShiftClosingDipsRequest request, ClaimsPrincipal user, ITenantGuard guard, IShiftService service, CancellationToken cancellationToken) =>
{
    var ownerId = ResolveOwnerId(user, null);
    if (!await guard.OwnsAsync(ownerId, TenantEntities.Shift, id, cancellationToken))
    {
        return Results.NotFound();
    }

    long? userId = long.TryParse(user.FindFirstValue(ClaimTypes.NameIdentifier), out var uid) ? uid : null;
    try
    {
        var saved = await service.SaveClosingDipsAsync(id, ownerId, userId, request.Dips ?? Array.Empty<ShiftClosingDipInput>(), cancellationToken);
        return Results.Ok(saved);
    }
    catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number is >= 50260 and <= 50263)
    {
        // SP ke apne saaf sandesh — "pehle shift band kariye", "tank is pump ka nahi".
        return Results.BadRequest(ex.Message);
    }
}).RequireAuthorization();

app.MapGet("/api/shifts/{id:long}/nozzle-readings", async (long id, ClaimsPrincipal user, ITenantGuard guard, IShiftService service, CancellationToken cancellationToken) =>
{
    var ownerId = ResolveOwnerId(user, null);
    if (!await guard.OwnsAsync(ownerId, TenantEntities.Shift, id, cancellationToken))
    {
        return Results.NotFound();
    }

    var items = await service.GetNozzleReadingsAsync(id, cancellationToken);
    return Results.Ok(items);
}).RequireAuthorization();

// Shift ka cash summary — doosre owner ki shift ka collection dikh jaata tha.
app.MapGet("/api/shifts/{id:long}/summary", async (long id, ClaimsPrincipal user, ITenantGuard guard, IShiftService service, CancellationToken cancellationToken) =>
{
    var ownerId = ResolveOwnerId(user, null);
    if (!await guard.OwnsAsync(ownerId, TenantEntities.Shift, id, cancellationToken))
    {
        return Results.NotFound();
    }

    var summary = await service.GetCollectionSummaryAsync(id, cancellationToken);
    return Results.Ok(summary);
}).RequireAuthorization();

// Physical cash denomination count (note-by-note) — DB me table+SP pehle se the,
// yahan tak koi endpoint hi nahi tha isliye counted amount hamesha 0 rehta tha.
// ── Nozzle-wise aadmi ka cash ──────────────────────────────────────────────
// Pump par har nozzle par alag aadmi hota hai. Shift shuru me use chhutta milta
// hai, baad me usse cash liya jaata hai. Cash lena shift band karne se ALAG hai —
// poore din ka cash raat me ek saath bhi liya ja sakta hai.

app.MapGet("/api/shifts/{id:long}/nozzle-cash", async (long id, ClaimsPrincipal user, ITenantGuard guard, PPMS.Application.Features.Shifts.IAttendantCashService service, CancellationToken cancellationToken) =>
{
    var ownerId = ResolveOwnerId(user, null);
    if (!await guard.OwnsAsync(ownerId, TenantEntities.Shift, id, cancellationToken))
    {
        return Results.NotFound();
    }

    var rows = await service.GetShiftCashAsync(id, ownerId, cancellationToken);
    return Results.Ok(rows);
}).RequireAuthorization();

app.MapPost("/api/shifts/{id:long}/nozzle-attendant", async (long id, PPMS.Application.Features.Shifts.SetAttendantRequest request, ClaimsPrincipal user, ITenantGuard guard, PPMS.Application.Features.Shifts.IAttendantCashService service, CancellationToken cancellationToken) =>
{
    var ownerId = ResolveOwnerId(user, null);
    if (!await guard.OwnsAsync(ownerId, TenantEntities.Shift, id, cancellationToken))
    {
        return Results.NotFound();
    }

    long? userId = long.TryParse(user.FindFirstValue(ClaimTypes.NameIdentifier), out var uid) ? uid : null;

    try
    {
        await service.SetAttendantAsync(request with { ShiftId = id }, userId, cancellationToken);
        return Results.Ok(new { Success = true });
    }
    catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number is >= 50110 and <= 50114)
    {
        return Results.BadRequest(new { Success = false, Message = ex.Message });
    }
}).RequireAuthorization();

app.MapPost("/api/shifts/{id:long}/collect-cash", async (long id, PPMS.Application.Features.Shifts.CollectCashRequest request, ClaimsPrincipal user, ITenantGuard guard, PPMS.Application.Features.Shifts.IAttendantCashService service, CancellationToken cancellationToken) =>
{
    var ownerId = ResolveOwnerId(user, null);
    if (!await guard.OwnsAsync(ownerId, TenantEntities.Shift, id, cancellationToken))
    {
        return Results.NotFound();
    }

    long? userId = long.TryParse(user.FindFirstValue(ClaimTypes.NameIdentifier), out var uid) ? uid : null;

    try
    {
        var result = await service.CollectCashAsync(request with { ShiftId = id }, userId, cancellationToken);
        return Results.Ok(result);
    }
    catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number is >= 50110 and <= 50114)
    {
        return Results.BadRequest(new { Success = false, Message = ex.Message });
    }
}).RequireAuthorization();

app.MapDelete("/api/shifts/{id:long}/collect-cash/{nozzleId:long}", async (long id, long nozzleId, ClaimsPrincipal user, ITenantGuard guard, PPMS.Application.Features.Shifts.IAttendantCashService service, CancellationToken cancellationToken) =>
{
    var ownerId = ResolveOwnerId(user, null);
    if (!await guard.OwnsAsync(ownerId, TenantEntities.Shift, id, cancellationToken))
    {
        return Results.NotFound();
    }

    long? userId = long.TryParse(user.FindFirstValue(ClaimTypes.NameIdentifier), out var uid) ? uid : null;
    await service.UndoCollectionAsync(id, nozzleId, userId, cancellationToken);
    return Results.Ok(new { Success = true });
}).RequireAuthorization();

// Jitna cash abhi tak nahi liya — chahe shift kab ki bhi ho.
app.MapGet("/api/nozzle-cash/pending", async (ClaimsPrincipal user, long? pumpId, DateOnly? fromDate, DateOnly? toDate, PPMS.Application.Features.Shifts.IAttendantCashService service, CancellationToken cancellationToken) =>
{
    var ownerId = ResolveOwnerId(user, null);
    var rows = await service.GetPendingAsync(ownerId, pumpId, fromDate, toDate, cancellationToken);
    return Results.Ok(rows);
}).RequireAuthorization();

app.MapGet("/api/reports/attendant-cash", async (ClaimsPrincipal user, long? pumpId, DateOnly fromDate, DateOnly toDate, PPMS.Application.Features.Shifts.IAttendantCashService service, CancellationToken cancellationToken) =>
{
    var ownerId = ResolveOwnerId(user, null);
    var rows = await service.GetAttendantReportAsync(ownerId, pumpId, fromDate, toDate, cancellationToken);
    return Results.Ok(rows);
}).RequireAuthorization();

app.MapPost("/api/shifts/{id:long}/cash-denomination", async (long id, SaveShiftCashDenominationRequest request, ClaimsPrincipal user, ITenantGuard guard, IShiftService service, CancellationToken cancellationToken) =>
{
    var ownerId = ResolveOwnerId(user, null);
    if (!await guard.OwnsAsync(ownerId, TenantEntities.Shift, id, cancellationToken))
    {
        return Results.NotFound();
    }

    var totalCounted = await service.SaveCashDenominationAsync(id, request, cancellationToken);
    return Results.Ok(new { TotalCounted = totalCounted });
}).RequireAuthorization();

app.MapGet("/api/sales", async (ClaimsPrincipal user, long? ownerId, long? pumpId, DateTime? fromDate, DateTime? toDate, string? searchTerm, int? pageNumber, int? pageSize, ISalesService service, CancellationToken cancellationToken) =>
{
    var resolvedOwnerId = ResolveOwnerId(user, ownerId);
    var pNum = pageNumber ?? 1;
    var pSize = pageSize ?? 50;
    var sales = await service.GetPagedListAsync(resolvedOwnerId, pumpId, fromDate, toDate, searchTerm, pNum, pSize, cancellationToken);
    return Results.Ok(sales);
}).RequireAuthorization();

app.MapPost("/api/sales", async (
    SaveSaleRequest request, 
    ISalesService service, 
    PPMS.Application.Features.Parties.IPartyQueryService partyService, 
    CancellationToken cancellationToken) =>
{
    if (request.Items is null || request.Items.Count == 0)
    {
        return Results.BadRequest("At least one sale item is required.");
    }

    if (request.ShiftId <= 0)
    {
        return Results.BadRequest("Valid open shift is required.");
    }

    if (string.Equals(request.PaymentMode, "Credit", StringComparison.OrdinalIgnoreCase))
    {
        if ((request.PartyId ?? 0) <= 0)
        {
            return Results.BadRequest("For Credit sale, party is required.");
        }

        var partyId = request.PartyId ?? 0;
        var party = await partyService.GetByIdAsync(partyId, request.OwnerId, request.PumpId, cancellationToken);
        
        if (party is null)
        {
            return Results.BadRequest("Selected credit party not found.");
        }

        var totalAmount = request.Items.Sum(x => x.Quantity * x.Rate);
        if (party.CreditLimit > 0 && (party.CurrentBalance + totalAmount) > party.CreditLimit)
        {
            return Results.BadRequest($"Credit limit exceeded. Limit is {party.CreditLimit:N2}, Current Balance is {party.CurrentBalance:N2}.");
        }
    }

    try
    {
        var id = await service.SaveAsync(request, cancellationToken);
        return Results.Ok(new { Id = id });
    }
    catch (InvalidOperationException ex)
    {
        return Results.BadRequest(ex.Message);
    }
}).RequireAuthorization();

// Bill ka receipt — koi bhi sale id daal kar doosre owner ka bill print kar sakta tha.
app.MapPost("/api/sales/{id:long}/receipt", async (long id, ClaimsPrincipal user, ITenantGuard guard, ISalesService service, CancellationToken cancellationToken) =>
{
    var ownerId = ResolveOwnerId(user, null);
    if (!await guard.OwnsAsync(ownerId, TenantEntities.Sale, id, cancellationToken))
    {
        return Results.NotFound();
    }

    var receipt = await service.GenerateReceiptAsync(id, cancellationToken);
    return receipt is null ? Results.NotFound() : Results.Ok(receipt);
}).RequireAuthorization();

app.MapDelete("/api/sales/{id:long}/void", async (long id, ClaimsPrincipal user, long? ownerId, string? reason, ISalesService service, CancellationToken cancellationToken) =>
{
    var resolvedOwnerId = ResolveOwnerId(user, ownerId);

    // Bill kaatna paisa nikalne ka sabse aasan raasta hai — isliye "kisne kaata"
    // audit me jaana chahiye. Claim se lete hain, client se nahi.
    long? userId = long.TryParse(user.FindFirstValue(ClaimTypes.NameIdentifier), out var uid) ? uid : null;

    try
    {
        await service.VoidAsync(id, resolvedOwnerId, userId, reason, cancellationToken);
        return Results.Ok(new { Success = true });
    }
    catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number == 50010)
    {
        return Results.NotFound("Sale not found or access denied.");
    }
}).RequireAuthorization();

app.MapDelete("/api/expenses/{id:long}", async (long id, ClaimsPrincipal user, long? ownerId, IExpenseService service, CancellationToken cancellationToken) =>
{
    var resolvedOwnerId = ResolveOwnerId(user, ownerId);
    try
    {
        await service.DeleteAsync(id, resolvedOwnerId, cancellationToken);
        return Results.Ok(new { Success = true });
    }
    catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number == 50011)
    {
        return Results.NotFound("Expense not found or access denied.");
    }
}).RequireAuthorization();

app.MapDelete("/api/purchase/{id:long}", async (long id, ClaimsPrincipal user, long? ownerId, IPurchaseService service, CancellationToken cancellationToken) =>
{
    var resolvedOwnerId = ResolveOwnerId(user, ownerId);
    try
    {
        await service.DeleteAsync(id, resolvedOwnerId, cancellationToken);
        return Results.Ok(new { Success = true });
    }
    catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number == 50012)
    {
        return Results.NotFound("Purchase not found or access denied.");
    }
}).RequireAuthorization();

// Returns last closed shift's closing reading per nozzle — used to pre-fill Open Shift form
// beforeDate: us tareekh (ya usse pehle) ki AAKHRI band shift ki reading.
// Bina iske "sabse baad me band hui" shift milti thi, jo purana din bharte
// waqt galat hoti hai.
app.MapGet("/api/pumps/{pumpId:long}/last-nozzle-readings", async (long pumpId, DateOnly? beforeDate, ClaimsPrincipal user, ITenantGuard guard, IShiftService service, CancellationToken cancellationToken) =>
{
    var ownerId = ResolveOwnerId(user, null);
    if (!await guard.OwnsAsync(ownerId, TenantEntities.Pump, pumpId, cancellationToken))
    {
        return Results.NotFound();
    }

    var readings = await service.GetLastNozzleReadingsAsync(pumpId, beforeDate, cancellationToken);
    return Results.Ok(readings);
}).RequireAuthorization();

// ── Support console (Section Z) ────────────────────────────────────────────────
// Sirf Super Admin. Yahan OwnerId JWT se NAHI aata — support wala kisi bhi owner
// ka data theek karta hai, isliye ownerId query se lena hi padta hai. Isi wajah
// se in teenon par "SuperAdminOnly" policy hai; aam user ke liye ye raasta band
// hai (TenantIsolationMiddleware ke niyam ka jaanbujh kar apvaad).

app.MapGet("/api/support/shifts", async (long ownerId, long? pumpId, int? days, IShiftService service, CancellationToken cancellationToken) =>
{
    if (ownerId <= 0) return Results.BadRequest(new { Success = false, Message = "ownerId is required." });
    var rows = await service.GetSupportShiftsAsync(ownerId, pumpId, days ?? 60, cancellationToken);
    return Results.Ok(rows);
}).RequireAuthorization("SuperAdminOnly");

app.MapPost("/api/support/shifts/{id:long}/reopen", async (long id, long ownerId, ClaimsPrincipal user, IShiftService service, CancellationToken cancellationToken) =>
{
    if (ownerId <= 0) return Results.BadRequest(new { Success = false, Message = "ownerId is required." });
    try
    {
        var userId = long.TryParse(user.FindFirstValue(ClaimTypes.NameIdentifier), out var uid) ? uid : (long?)null;
        await service.ReopenShiftAsync(id, ownerId, userId, cancellationToken);
        return Results.Ok(new { Success = true });
    }
    catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number >= 50240 && ex.Number <= 50243)
    {
        // 50240-50243 = Section Y ki apni rok (shift mili nahi / pehle se khuli /
        // doosri khuli hai / stock hil chuka hai). User ki galti hai, 500 nahi.
        return Results.BadRequest(new { Success = false, Message = ex.Message });
    }
}).RequireAuthorization("SuperAdminOnly");

app.MapDelete("/api/support/shifts/{id:long}", async (long id, long ownerId, string? reason, ClaimsPrincipal user, IShiftService service, CancellationToken cancellationToken) =>
{
    if (ownerId <= 0) return Results.BadRequest(new { Success = false, Message = "ownerId is required." });
    try
    {
        var userId = long.TryParse(user.FindFirstValue(ClaimTypes.NameIdentifier), out var uid) ? uid : (long?)null;
        await service.DeleteShiftAsync(id, ownerId, userId, reason, cancellationToken);
        return Results.Ok(new { Success = true });
    }
    catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number >= 50250 && ex.Number <= 50255)
    {
        // 50250-50255 = Section Z ki rok: shift khaali nahi hai.
        return Results.BadRequest(new { Success = false, Message = ex.Message });
    }
}).RequireAuthorization("SuperAdminOnly");

app.MapGet("/api/support/meter-chain", async (long ownerId, long? pumpId, int? days, IShiftService service, CancellationToken cancellationToken) =>
{
    if (ownerId <= 0) return Results.BadRequest(new { Success = false, Message = "ownerId is required." });
    // Wahi jaanch jo owner apne Shifts page par dekhta hai — bas kisi bhi owner ke liye.
    var gaps = await service.GetMeterChainGapsAsync(ownerId, pumpId, days ?? 90, cancellationToken);
    return Results.Ok(gaps);
}).RequireAuthorization("SuperAdminOnly");

app.MapPost("/api/support/parties/recalculate", async (long ownerId, long? partyId, IPartyCommandService service, CancellationToken cancellationToken) =>
{
    if (ownerId <= 0) return Results.BadRequest(new { Success = false, Message = "ownerId is required." });
    var updated = await service.RecalculateBalancesAsync(ownerId, partyId, cancellationToken);
    return Results.Ok(new { Success = true, UpdatedParties = updated });
}).RequireAuthorization("SuperAdminOnly");

app.Run();
