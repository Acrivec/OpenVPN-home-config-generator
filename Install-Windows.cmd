@echo off
setlocal
set "OPENVPN_CLIENT_INSTALLER=%~dp0Install-OpenVPN-Client-Windows.ps1"

if not exist "%OPENVPN_CLIENT_INSTALLER%" (
    echo ERROR: Install-OpenVPN-Client-Windows.ps1 was not found beside this launcher.
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$script = $env:OPENVPN_CLIENT_INSTALLER; $argLine = '-NoProfile -ExecutionPolicy Bypass -NoExit -File ' + [char]34 + $script + [char]34; try { Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argLine -Wait -ErrorAction Stop } catch { Write-Error $_; exit 1 }"
if errorlevel 1 (
    echo The elevated installer could not be started. Try right-clicking this file and selecting Run as administrator.
    pause
    exit /b 1
)
