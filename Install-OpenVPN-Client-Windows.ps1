#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$ProfilePath
)

$ErrorActionPreference = 'Stop'

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdministrator)) {
    throw 'Run this script from an elevated PowerShell window (Run as Administrator).'
}

if ([string]::IsNullOrWhiteSpace($ProfilePath)) {
    $profiles = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ovpn' -File -ErrorAction Stop)
    if ($profiles.Count -ne 1) {
        throw "Expected exactly one .ovpn profile beside this script; found $($profiles.Count). Pass the profile path explicitly: .\Install-OpenVPN-Client-Windows.ps1 -ProfilePath .\device.ovpn"
    }
    $ProfilePath = $profiles[0].FullName
}
if (-not (Test-Path -LiteralPath $ProfilePath -PathType Leaf)) {
    throw "Client profile not found: $ProfilePath"
}
$ProfilePath = (Resolve-Path -LiteralPath $ProfilePath).Path
$profileText = Get-Content -LiteralPath $ProfilePath -Raw
foreach ($requiredMarker in @('(?im)^client\s*$', '(?im)^remote\s+', '(?im)^<ca>\s*$', '(?im)^<cert>\s*$', '(?im)^<key>\s*$', '(?im)^<tls-crypt>\s*$')) {
    if ($profileText -notmatch $requiredMarker) {
        throw "The selected file does not appear to be a complete self-contained client profile (missing marker: $requiredMarker)."
    }
}

$profileName = [IO.Path]::GetFileNameWithoutExtension($ProfilePath).ToLowerInvariant() -replace '[^a-z0-9_-]+', '-'
$profileName = $profileName.Trim('-')
if ([string]::IsNullOrWhiteSpace($profileName)) { $profileName = 'device' }
if ($profileName.Length -gt 40) { $profileName = $profileName.Substring(0, 40) }
$deployedName = "HomeVPN-$profileName.ovpn"

$installDir = Join-Path $env:ProgramFiles 'OpenVPN'
$openVpnExe = Join-Path $installDir 'bin\openvpn.exe'
$openVpnInstalled = Test-Path -LiteralPath $openVpnExe
$existingService = Get-Service -Name 'OpenVPNService' -ErrorAction SilentlyContinue
$shouldInstallMsi = -not $openVpnInstalled
if ($openVpnInstalled -and -not $existingService) {
    Write-Warning 'OpenVPN is installed, but its persistent OpenVPNService component is missing.'
    Write-Warning 'The client installer needs that service to connect automatically at system startup.'
    $approval = Read-Host 'Modify OpenVPN and install the current 2.7.8-I002 service/Wintun components? This may upgrade the existing OpenVPN version. Type Y to continue'
    if ($approval -notmatch '^(?i:y)$') {
        throw 'No changes made. Install/enable the OpenVPNService component manually, then rerun this client installer.'
    }
    $shouldInstallMsi = $true
}

if ($shouldInstallMsi) {
    $architecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
    switch ($architecture) {
        'x64'   { $msiArchitecture = 'amd64' }
        'arm64' { $msiArchitecture = 'arm64' }
        'x86'   { $msiArchitecture = 'x86' }
        default { throw "Unsupported Windows architecture '$architecture'. Install OpenVPN Community manually, then rerun this client installer." }
    }

    # Pinned to the current official Community MSI release. If a pre-existing
    # installation lacks the system service, the user must approve modification.
    $openVpnVersion = '2.7.8-I002'
    $msiName = "OpenVPN-$openVpnVersion-$msiArchitecture.msi"
    $msiUrl = "https://swupdate.openvpn.org/community/releases/$msiName"
    $msiPath = Join-Path $env:TEMP $msiName
    $signaturePath = "$msiPath.asc"
    if ($openVpnInstalled) {
        Write-Host "Downloading the official OpenVPN Community $openVpnVersion MSI to add the missing service component..." -ForegroundColor Cyan
    }
    else {
        Write-Host "OpenVPN is not installed. Downloading the official OpenVPN Community $openVpnVersion MSI..." -ForegroundColor Cyan
    }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $msiUrl -OutFile $msiPath -UseBasicParsing

    # Prefer the project's detached GPG signature when GnuPG is available. The
    # fallback accepts only a valid Windows Authenticode signature from OpenVPN.
    $verified = $false
    $gpgCommand = Get-Command 'gpg.exe' -ErrorAction SilentlyContinue
    if (-not $gpgCommand) { $gpgCommand = Get-Command 'gpg' -ErrorAction SilentlyContinue }
    if ($gpgCommand) {
        $keyPath = Join-Path $env:TEMP 'openvpn-security-key.asc'
        $gpgHome = Join-Path $env:TEMP ('openvpn-gpg-verify-' + [guid]::NewGuid().ToString('N'))
        try {
            Invoke-WebRequest -Uri ($msiUrl + '.asc') -OutFile $signaturePath -UseBasicParsing
            $keyUrl = 'https://keys.openpgp.org/vks/v1/by-fingerprint/F554A3687412CFFEBDEFE0A312F5F7B42F2B01E7'
            Invoke-WebRequest -Uri $keyUrl -OutFile $keyPath -UseBasicParsing
            New-Item -ItemType Directory -Path $gpgHome -Force | Out-Null
            & $gpgCommand.Path '--homedir' $gpgHome '--batch' '--import' $keyPath 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'Could not import the official OpenVPN GPG key.' }
            $keyListing = @(& $gpgCommand.Path '--homedir' $gpgHome '--batch' '--with-colons' '--fingerprint' '--list-keys' 2>$null)
            $fingerprints = @($keyListing | ForEach-Object {
                if ($_ -match '^fpr:::::::::([0-9A-F]+):') { $Matches[1].ToUpperInvariant() }
            })
            if ($fingerprints -notcontains 'F554A3687412CFFEBDEFE0A312F5F7B42F2B01E7') {
                throw 'The imported OpenVPN GPG key fingerprint does not match the official pinned fingerprint.'
            }
            # --status-fd provides locale-independent verification status.
            $gpgOutput = (& $gpgCommand.Path '--homedir' $gpgHome '--batch' '--status-fd' '1' '--verify' $signaturePath $msiPath 2>&1 | Out-String)
            $gpgExitCode = $LASTEXITCODE
            if ($gpgExitCode -eq 0 -and $gpgOutput -match '(?m)^\[GNUPG:\] VALIDSIG [0-9A-F]{40} ') {
                $verified = $true
                Write-Host 'OpenVPN GPG release signature verified against the pinned project key.' -ForegroundColor Green
            }
            else {
                Write-Warning 'The detached GPG signature did not verify; checking for a trusted Authenticode signature as a fallback.'
            }
        }
        catch {
            Write-Warning "GPG verification could not be completed: $($_.Exception.Message)"
        }
        finally {
            Remove-Item -LiteralPath $gpgHome -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $keyPath -Force -ErrorAction SilentlyContinue
        }
    }

    if (-not $verified) {
        $authenticode = Get-AuthenticodeSignature -FilePath $msiPath
        if ($authenticode.Status -eq [System.Management.Automation.SignatureStatus]::Valid -and
            $authenticode.SignerCertificate -and
            $authenticode.SignerCertificate.Subject -match '(?i)OpenVPN') {
            $verified = $true
            Write-Host 'OpenVPN MSI Authenticode signature is valid.' -ForegroundColor Green
        }
    }
    if (-not $verified) {
        Remove-Item -LiteralPath $msiPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $signaturePath -Force -ErrorAction SilentlyContinue
        throw 'The MSI could not be authenticated. Install GnuPG (Gpg4win) and rerun, or verify the official OpenVPN signature manually. No installation was started.'
    }

    Write-Host 'Installing OpenVPN Community with its GUI, background service, and network drivers...' -ForegroundColor Cyan
    $process = Start-Process -FilePath "$env:SystemRoot\System32\msiexec.exe" -ArgumentList "/i `"$msiPath`" ADDLOCAL=ALL /qn /norestart" -Wait -PassThru
    if ($process.ExitCode -notin @(0, 3010)) {
        throw "OpenVPN MSI installation failed with exit code $($process.ExitCode). The MSI is at $msiPath"
    }
    if ($process.ExitCode -eq 3010) {
        Write-Warning 'OpenVPN installation completed; Windows reports that a reboot is required to finish driver setup.'
    }
    Remove-Item -LiteralPath $msiPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $signaturePath -Force -ErrorAction SilentlyContinue
}

if (-not (Test-Path -LiteralPath $openVpnExe)) {
    throw "OpenVPN executable was not found at '$openVpnExe' after installation. Install/repair OpenVPN Community manually and rerun."
}
$versionLine = (& $openVpnExe --version 2>$null | Select-Object -First 1)
if ($versionLine -notmatch 'OpenVPN\s+(\d+)\.(\d+)\.(\d+)') {
    throw "Could not determine the installed OpenVPN version from: '$versionLine'"
}
$installedVersion = [version]("$($Matches[1]).$($Matches[2]).$($Matches[3])")
if ($installedVersion -lt [version]'2.5.0') {
    throw "OpenVPN $installedVersion is too old. This client profile requires OpenVPN 2.5.0 or newer. Update it manually; this script does not upgrade existing installations."
}
Write-Host "Using OpenVPN $installedVersion." -ForegroundColor Green

$service = Get-Service -Name 'OpenVPNService' -ErrorAction SilentlyContinue
if (-not $service) {
    throw 'The OpenVPNService system service was not installed. Repair/reinstall OpenVPN Community with its service component enabled, then rerun this script.'
}

$registry = Get-ItemProperty -Path 'HKLM:\SOFTWARE\OpenVPN' -ErrorAction SilentlyContinue
$configDir = [string]$registry.autostart_config_dir
if ([string]::IsNullOrWhiteSpace($configDir)) {
    $configDir = Join-Path $installDir 'config-auto'
}
$configDir = [Environment]::ExpandEnvironmentVariables($configDir.Trim().TrimEnd('\','/'))
New-Item -ItemType Directory -Path $configDir -Force | Out-Null
$destination = Join-Path $configDir $deployedName
if (Test-Path -LiteralPath $destination) {
    $backup = "$destination.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Copy-Item -LiteralPath $destination -Destination $backup -Force
    Write-Host "Existing profile backed up to: $backup" -ForegroundColor Yellow
}
Copy-Item -LiteralPath $ProfilePath -Destination $destination -Force

# The system service runs under its virtual service account. Grant it read access
# while keeping the embedded client private key out of ordinary user ACLs.
$serviceAccount = 'NT SERVICE\OpenVPNService'
$icacls = Join-Path $env:SystemRoot 'System32\icacls.exe'
& $icacls $configDir '/grant' "${serviceAccount}:(RX)" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Could not grant OpenVPNService directory access to $configDir" }
& $icacls $destination '/inheritance:r' '/grant:r' '*S-1-5-18:F' '*S-1-5-32-544:F' "${serviceAccount}:(R)" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Could not secure the deployed client profile ACL: $destination" }

Set-Service -Name 'OpenVPNService' -StartupType Automatic
$wasRunning = (Get-Service -Name 'OpenVPNService').Status -eq 'Running'
if ($wasRunning) {
    Restart-Service -Name 'OpenVPNService' -Force
}
else {
    Start-Service -Name 'OpenVPNService'
}

$service = Get-Service -Name 'OpenVPNService'
if ($service.Status -ne 'Running') {
    throw "OpenVPNService did not remain running (status: $($service.Status)). Check Windows Event Viewer and the OpenVPN logs."
}

$logDir = [string]$registry.log_dir
if ([string]::IsNullOrWhiteSpace($logDir)) { $logDir = Join-Path $env:ProgramData 'OpenVPN\Log' }
$logDir = [Environment]::ExpandEnvironmentVariables($logDir.Trim().TrimEnd('\','/'))
$clientLog = Join-Path $logDir ([IO.Path]::GetFileNameWithoutExtension($deployedName) + '.log')

Write-Host ''
Write-Host 'Client profile installed.' -ForegroundColor Green
Write-Host "Profile: $destination"
Write-Host 'OpenVPNService: Running (Automatic).'
Write-Host 'The service will connect automatically at system startup, before user logon.'
if (Test-Path -LiteralPath $clientLog) {
    $recentLog = Get-Content -LiteralPath $clientLog -Tail 80 -ErrorAction SilentlyContinue
    if ($recentLog -match 'Initialization Sequence Completed') {
        Write-Host 'VPN connection: Initialization Sequence Completed.' -ForegroundColor Green
    }
    else {
        Write-Warning 'The service is running, but the profile log does not yet show a completed VPN connection. It will continue retrying according to the profile.'
        Write-Host "Recent log: $clientLog"
    }
}
else {
    Write-Warning 'The service is running. A connection is not confirmed yet; check the per-profile log after the first connection attempt.'
    Write-Host "Expected log: $clientLog"
}
Write-Host ''
Write-Host 'To inspect the client log:'
Write-Host "Get-Content -LiteralPath '$clientLog' -Tail 60"
Write-Warning 'The deployed .ovpn contains this device private key. Keep the profile private and do not reuse it on another device.'
