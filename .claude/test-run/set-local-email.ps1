# Ek baar chalayein: Gmail ki email setting aapke Windows user me (repo / file me nahi).
# Password type karte waqt screen par nahi dikhta; space apne aap hat jaati hai.
$sec = Read-Host "Gmail app password (16 akshar)" -AsSecureString
$pass = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)) -replace '\s', ''
[Environment]::SetEnvironmentVariable('Email__Host', 'smtp.gmail.com', 'User')
[Environment]::SetEnvironmentVariable('Email__Port', '587', 'User')
[Environment]::SetEnvironmentVariable('Email__Username', 'petrolpumpms@gmail.com', 'User')
[Environment]::SetEnvironmentVariable('Email__From', 'petrolpumpms@gmail.com', 'User')
[Environment]::SetEnvironmentVariable('Email__Password', $pass, 'User')
Remove-Variable pass, sec
"Password length: " + [Environment]::GetEnvironmentVariable('Email__Password', 'User').Length + " (16 hona chahiye)"
