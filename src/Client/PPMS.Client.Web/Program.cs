using System.Globalization;
using Microsoft.AspNetCore.DataProtection;
using Microsoft.AspNetCore.HttpOverrides;
using Microsoft.AspNetCore.Localization;
using PPMS.Client.Web.Services;

var builder = WebApplication.CreateBuilder(args);

// ── Language (English default, Hindi optional) ────────────────────────────────
// View me English text hi key hai (@L["Save"]). "en" par koi resource dhoondha
// nahi jaata — key hi dikh jaati hai. Hindi ke liye Resources/SharedResource.hi.resx
// me tarjuma hai. User header ke dropdown se bhasha badal sakta hai; choice ek
// cookie me 1 saal tak yaad rehti hai.
var supportedCultures = new[] { new CultureInfo("en"), new CultureInfo("hi") };

builder.Services.AddLocalization(options => options.ResourcesPath = "Resources");
builder.Services.Configure<RequestLocalizationOptions>(options =>
{
    options.DefaultRequestCulture = new RequestCulture("en");
    options.SupportedCultures = supportedCultures;
    options.SupportedUICultures = supportedCultures;
    // Cookie sabse pehle dekho — browser ki Accept-Language se pehle user ki apni
    // pasand chalni chahiye.
    options.RequestCultureProviders.Insert(0, new CookieRequestCultureProvider());
});

// Add services to the container.
builder.Services.AddControllersWithViews()
    .AddViewLocalization()
    .AddDataAnnotationsLocalization();
builder.Services.AddHttpContextAccessor();

// Session in-memory thi, isliye 2+ server (load balancer ke peeche) laga hi nahi
// sakte the — ek server par login karo to doosre par session nahi milta. Redis
// connection string configured ho to session wahan store hoti hai (sab server
// share karte hain); nahi to purana in-memory behavior hi chalta hai (single
// server ke liye abhi bhi theek hai).
var redisConnectionString = builder.Configuration["Redis:ConnectionString"];
if (!string.IsNullOrWhiteSpace(redisConnectionString))
{
    builder.Services.AddStackExchangeRedisCache(options =>
    {
        options.Configuration = redisConnectionString;
        options.InstanceName = "PPMS.Client.Session:";
    });

    // Data Protection keys bhi Redis par — warna har server ka apna alag key ring
    // hoga aur ek server par bana session/antiforgery cookie doosre server par
    // invalid ho jayega (session Redis me shared hone ke bawajood).
    builder.Services.AddDataProtection()
        .PersistKeysToStackExchangeRedis(
            StackExchange.Redis.ConnectionMultiplexer.Connect(redisConnectionString),
            "PPMS.Client.DataProtection-Keys");
}
else
{
    builder.Services.AddDistributedMemoryCache();
}

builder.Services.AddSession(options =>
{
    options.Cookie.Name = "PPMS.Client.Session";
    options.Cookie.HttpOnly = true;      // JavaScript cookie padh na sake
    options.Cookie.IsEssential = true;
    // Ye do pehle set hi nahi the:
    //   SecurePolicy — SameAsRequest matlab HTTPS par cookie sirf HTTPS par jayegi,
    //   aur local http par dev chalta rahega. Pehle default (None) tha, yaani
    //   koi hamlawar plain http:// par ek request karwa kar session cookie
    //   network par bhej sakta tha.
    //   SameSite=Lax — doosri site se aayi request ke saath cookie na jaye (CSRF).
    options.Cookie.SecurePolicy = CookieSecurePolicy.SameAsRequest;
    options.Cookie.SameSite = SameSiteMode.Lax;
    options.IdleTimeout = TimeSpan.FromHours(8);
});

// Antiforgery token JavaScript se bhi bheja ja sake (fetch wale POST ke liye).
builder.Services.AddAntiforgery(options => options.HeaderName = "RequestVerificationToken");

// Support ke number (Section AR) - chhota cache, Super Admin save par saaf.
builder.Services.AddMemoryCache();
builder.Services.AddScoped<PPMS.Client.Web.Services.SupportContactService>();
// Grahak ka asli IP API tak (login / sign-up ki per-IP rok ke liye) - ForwardUserIpHandler dekho.
builder.Services.AddTransient<PPMS.Client.Web.Services.ForwardUserIpHandler>();
builder.Services.AddHttpClient<PPMSApiClient>((sp, client) =>
{
    var config = sp.GetRequiredService<IConfiguration>();
    var baseUrl = config["Api:BaseUrl"] ?? "http://localhost:5000";
    client.BaseAddress = new Uri(baseUrl);

    // ModSecurity rule 920320 blocks requests without User-Agent header
    // Isliye yahan User-Agent add kar rahe hain
    client.DefaultRequestHeaders.Add("User-Agent", "PPMS-Client/1.0 (Internal)");
})
.ConfigurePrimaryHttpMessageHandler((sp) =>
{
    var handler = new HttpClientHandler();
    // Certificate validation sirf Development me bypass — production me API ka
    // asal certificate validate hona chahiye, warna client bina TLS check ke
    // MITM ko bhi accept kar lega.
    //
    // Iska seedha nateeja: API par valid SSL certificate hona ZAROORI hai.
    // 2026-09-06 par ppmsapi.bringingarcher.com par Plesk ka default self-signed
    // certificate laga tha (4 May 2023 ko expire ho chuka), to production client
    // TLS handshake par hi ruk gaya aur page par "API unreachable. Check API
    // server is running." dikhne laga — jabki API bilkul theek chal rahi thi.
    // Ilaaj: API wale domain par Let's Encrypt lagao. Ye check band mat karna.
    if (sp.GetRequiredService<IWebHostEnvironment>().IsDevelopment())
    {
        handler.ServerCertificateCustomValidationCallback =
            HttpClientHandler.DangerousAcceptAnyServerCertificateValidator;
    }
    return handler;
})
.AddHttpMessageHandler<PPMS.Client.Web.Services.ForwardUserIpHandler>();

var app = builder.Build();

// IIS/reverse-proxy TLS termination karta hai aur Kestrel ko plain HTTP forward
// karta hai — X-Forwarded-* headers ke bina UseHttpsRedirection() galat scheme
// dekh kar redirect loop bana sakta tha.
app.UseForwardedHeaders(new ForwardedHeadersOptions
{
    ForwardedHeaders = ForwardedHeaders.XForwardedFor | ForwardedHeaders.XForwardedProto
});

// Configure the HTTP request pipeline.
if (!app.Environment.IsDevelopment())
{
    app.UseExceptionHandler("/Home/Error");
    app.UseHsts();
}
app.UseHttpsRedirection();
// Har request par bhasha set karo (cookie se) — routing se pehle, taaki views ko
// sahi culture mile.
app.UseRequestLocalization(app.Services
    .GetRequiredService<Microsoft.Extensions.Options.IOptions<RequestLocalizationOptions>>().Value);

// Security headers — ye pehle bilkul nahi the.
app.Use(async (ctx, next) =>
{
    var h = ctx.Response.Headers;
    h["X-Content-Type-Options"] = "nosniff";
    h["X-Frame-Options"] = "DENY";               // clickjacking se bachav
    h["Referrer-Policy"] = "no-referrer";
    h["X-Permitted-Cross-Domain-Policies"] = "none";
    await next();
});

app.UseRouting();
app.UseStaticFiles();
app.UseSession();
app.Use(async (context, next) =>
{
    var path = context.Request.Path.Value ?? string.Empty;
    var isAuthPage = path.StartsWith("/Account/Login", StringComparison.OrdinalIgnoreCase)
        || path.StartsWith("/Account/Logout", StringComparison.OrdinalIgnoreCase);

    if (!isAuthPage)
    {
        var accessToken = context.Session.GetString("access_token");
        var refreshToken = context.Session.GetString("refresh_token");
        var accessExpiryRaw = context.Session.GetString("access_token_expires_utc");

        if (!string.IsNullOrWhiteSpace(accessToken) &&
            !string.IsNullOrWhiteSpace(refreshToken) &&
            DateTime.TryParse(accessExpiryRaw, out var accessExpiryUtc) &&
            accessExpiryUtc <= DateTime.UtcNow.AddMinutes(1))
        {
            var apiClient = context.RequestServices.GetRequiredService<PPMS.Client.Web.Services.PPMSApiClient>();
            var refreshed = await apiClient.RefreshAsync(refreshToken, context.RequestAborted);
            if (refreshed is not null)
            {
                context.Session.SetString("access_token", refreshed.Token);
                context.Session.SetString("refresh_token", refreshed.RefreshToken);
                context.Session.SetString("access_token_expires_utc", refreshed.AccessTokenExpiresOnUtc.ToString("O"));
                context.Session.SetString("refresh_token_expires_utc", refreshed.RefreshTokenExpiresOnUtc.ToString("O"));
            }
            else
            {
                context.Session.Clear();
            }
        }
    }

    await next();
});

app.UseAuthorization();

app.MapControllerRoute(
    name: "default",
    pattern: "{controller=Home}/{action=Index}/{id?}");


app.Run();
