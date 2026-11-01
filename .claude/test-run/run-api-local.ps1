# LOCAL chalane ke liye (asli email ke saath): API ko LocalDB ke PPMSDB par chalata hai.
# appsettings.Development.json LIVE ki taraf ishara karta hai - env var usse upar rehte hain.
# Email__* aapke Windows user ki setting se (set-local-email.ps1 ek baar chalayein) - password
# kisi file / repo me nahi. WhatsApp / SMS band (Twilio token nakli).
param([string]$Db = "PPMSDB")
$cs = "Server=(localdb)\MSSQLLocalDB;Database=$Db;Trusted_Connection=True;TrustServerCertificate=True;MultipleActiveResultSets=true"
$env:ASPNETCORE_ENVIRONMENT = "Development"
$env:ASPNETCORE_URLS = "http://localhost:5258"
$env:ConnectionStrings__DefaultConnection = $cs
$env:Database__ConnectionString = $cs
$env:Notification__Twilio_AuthToken = "disabled-for-local-test"
$env:Backup__Enabled = "false"
$env:TenantBackup__Path = (Join-Path $PSScriptRoot "..\backups\local-tenant-deletes")
# App chalu hone ke baad set hui User env var is process me apne aap nahi aati - registry se padho.
foreach ($k in 'Email__Host', 'Email__Port', 'Email__EnableSsl', 'Email__Username', 'Email__Password', 'Email__From', 'Email__FromName') {
    $v = [Environment]::GetEnvironmentVariable($k, 'User')
    if ($v) { Set-Item -Path "env:$k" -Value $v }
}
$bin = Join-Path $PSScriptRoot "..\..\src\API\PPMS.Api\bin\Debug\net8.0"
Set-Location $bin
& dotnet PPMS.Api.dll
