# Sirf LOCAL TEST ke liye: Client ko local API (http://localhost:5258) par chalata hai.
$env:ASPNETCORE_ENVIRONMENT = "Development"
$env:ASPNETCORE_URLS = "http://localhost:5131"
$env:Api__BaseUrl = "http://localhost:5258"
$bin = Join-Path $PSScriptRoot "..\..\src\Client\PPMS.Client.Web\bin\Debug\net8.0"
Set-Location $bin
& dotnet PPMS.Client.Web.dll
