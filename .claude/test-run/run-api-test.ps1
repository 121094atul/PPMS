# Sirf LOCAL TEST ke liye: API ko LocalDB ke test DB par chalata hai.
# appsettings.Development.json LIVE ki taraf ishara karta hai — env var usse upar rehte hain.
param([string]$Db = "PPMS_TS_TEST")
$cs = "Server=(localdb)\MSSQLLocalDB;Database=$Db;Trusted_Connection=True;TrustServerCertificate=True;MultipleActiveResultSets=true"
$env:ASPNETCORE_ENVIRONMENT = "Development"
$env:ASPNETCORE_URLS = "http://localhost:5258"
$env:ConnectionStrings__DefaultConnection = $cs
$env:Database__ConnectionString = $cs
$env:Notification__Twilio_AuthToken = "disabled-for-local-test"
$env:Backup__Enabled = "false"
$bin = Join-Path $PSScriptRoot "..\..\src\API\PPMS.Api\bin\Debug\net8.0"
Set-Location $bin
& dotnet PPMS.Api.dll
