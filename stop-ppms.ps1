# PPMS ke chalu server band karo. Build ke waqt jo
# "file is locked by .NET Host" error aata hai, wo isi wajah se hai.
# Build se pehle ye chala lo:  powershell -File stop-ppms.ps1

Get-Process -Name "PPMS.Api","PPMS.Client.Web" -ErrorAction SilentlyContinue |
    ForEach-Object {
        Write-Host "band kar rahe: $($_.Name) (PID $($_.Id))"
        Stop-Process -Id $_.Id -Force
    }

# "dotnet run" se chale server PPMS.exe ke naam se nahi dikhte, dotnet ke
# naam se dikhte hain - isliye unhe port se dhoondhte hain.
foreach ($port in 5258, 5259, 5131) {
    Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty OwningProcess -Unique |
        ForEach-Object {
            Write-Host "port $port chhod rahe: PID $_"
            Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue
        }
}

& dotnet build-server shutdown | Out-Null
Start-Sleep -Seconds 2
Write-Host "Ho gaya - ab build kar sakte hain." -ForegroundColor Green
