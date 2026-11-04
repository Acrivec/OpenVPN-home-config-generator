#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ServerDir
)

$ErrorActionPreference = 'Stop'

# The kit uses modern OpenVPN 2.6+ directives. OpenVPN itself is never
# downloaded, upgraded, or installed by this script.
$minimumOpenVPNVersion = [version]'2.6.0'
$recommendedOpenVPNVersion = [version]'2.7.8'

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdministrator)) {
    throw 'Run this script from an elevated PowerShell window (Run as Administrator).'
}

if ([string]::IsNullOrWhiteSpace($ServerDir)) {
    $ServerDir = Join-Path $PSScriptRoot 'OpenVPN-VPN\server'
    if (-not (Test-Path (Join-Path $ServerDir 'server.ovpn'))) {
        $ServerDir = Join-Path $PSScriptRoot 'server'
    }
}
$ServerDir = (Resolve-Path -Path $ServerDir).Path
$requiredFiles = @('server.ovpn', 'ca.crt', 'server.crt', 'server.key', 'tls-crypt.key')
foreach ($file in $requiredFiles) {
    if (-not (Test-Path (Join-Path $ServerDir $file))) { throw "Missing $file in $ServerDir" }
}

$installDir = Join-Path $env:ProgramFiles 'OpenVPN'
$openVpnExe = Join-Path $installDir 'bin\openvpn.exe'
$service = Get-Service -Name 'OpenVPNService' -ErrorAction SilentlyContinue

# This is a configuration/deployment script, not an OpenVPN installer.
# Never download an MSI, change the installed OpenVPN version, or run msiexec.
if (-not (Test-Path -LiteralPath $openVpnExe)) {
    throw "OpenVPN was not found at '$openVpnExe'. This script does not download or install OpenVPN. Install OpenVPN Community (including OpenVPNService and the TAP-Windows driver) manually, then rerun this script."
}
if (-not $service) {
    throw "The OpenVPNService system service was not found. This script does not install or repair OpenVPN. Verify that OpenVPN Community was installed with its service component enabled, then rerun."
}

$versionLine = (& $openVpnExe --version 2>$null | Select-Object -First 1)
$installedVersion = $null
if ($versionLine -match 'OpenVPN\s+(\d+)\.(\d+)\.(\d+)') {
    $installedVersion = [version]("$($Matches[1]).$($Matches[2]).$($Matches[3])")
}
if ($null -eq $installedVersion) {
    throw "Could not determine the installed OpenVPN version from: '$versionLine'. No software was installed or changed."
}
if ($installedVersion -lt $minimumOpenVPNVersion) {
    throw "OpenVPN $installedVersion is too old for this kit. OpenVPN 2.6.0 or newer is required. Update OpenVPN manually, then rerun this script. This script will not download or install an MSI."
}
if ($installedVersion -lt $recommendedOpenVPNVersion) {
    Write-Warning "Detected OpenVPN $installedVersion. The current recommended release is $recommendedOpenVPNVersion. The kit's Windows configuration uses features supported by OpenVPN 2.6+, so continuing without an automatic upgrade. Update OpenVPN manually when convenient."
}
else {
    Write-Host "Using installed OpenVPN $installedVersion. No OpenVPN download or installation will be attempted." -ForegroundColor Green
}

$configDir = Join-Path $installDir 'config-auto'
New-Item -ItemType Directory -Path $configDir -Force | Out-Null
$ccdTarget = Join-Path $configDir 'ccd'
New-Item -ItemType Directory -Path $ccdTarget -Force | Out-Null

# Resolve OpenVPN 2.7's Windows service log directory from the MSI registry.
$openVpnRegistry = Get-ItemProperty 'HKLM:\SOFTWARE\OpenVPN' -ErrorAction SilentlyContinue
$openVpnLogDir = [string]$openVpnRegistry.log_dir
if ([string]::IsNullOrWhiteSpace($openVpnLogDir)) {
    $openVpnLogDir = Join-Path $env:ProgramData 'OpenVPN\Log'
}
$openVpnLogDir = [Environment]::ExpandEnvironmentVariables($openVpnLogDir.Trim().TrimEnd('\','/'))
New-Item -ItemType Directory -Path $openVpnLogDir -Force | Out-Null
$openVpnLog = Join-Path $openVpnLogDir 'server.log'

# Select the existing TAP-Windows interface by its Network Connections alias.
# The alias is persisted so subsequent installer runs have a useful default.
$adapterNamePath = Join-Path $configDir 'tap-adapter-name.txt'
$savedTapAdapterName = ''
if (Test-Path $adapterNamePath) {
    $savedTapAdapterName = (Get-Content -Path $adapterNamePath -Raw).Trim()
}
$tapAdapters = @(Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue |
    Where-Object { $_.InterfaceDescription -match '(?i)TAP[- ]Windows' } |
    Sort-Object Name)
if ($tapAdapters.Count -eq 0) {
    throw 'No TAP-Windows adapter was found. Confirm the OpenVPN TAP-Windows driver is installed, then rerun this installer.'
}
Write-Host 'Detected TAP-Windows adapters:' -ForegroundColor Cyan
foreach ($adapter in $tapAdapters) {
    Write-Host ("  {0}  [{1}]" -f $adapter.Name, $adapter.InterfaceDescription)
}
$defaultTapAdapterName = ''
if (-not [string]::IsNullOrWhiteSpace($savedTapAdapterName) -and $tapAdapters.Name -contains $savedTapAdapterName) {
    $defaultTapAdapterName = $savedTapAdapterName
}
elseif ($tapAdapters.Count -eq 1) {
    $defaultTapAdapterName = $tapAdapters[0].Name
}
while ($true) {
    if ([string]::IsNullOrWhiteSpace($defaultTapAdapterName)) {
        $tapAdapterName = (Read-Host 'Enter the exact TAP-Windows adapter name shown above').Trim()
    }
    else {
        $tapAdapterName = Read-Host "TAP-Windows adapter name [$defaultTapAdapterName]"
        if ([string]::IsNullOrWhiteSpace($tapAdapterName)) { $tapAdapterName = $defaultTapAdapterName }
        $tapAdapterName = $tapAdapterName.Trim()
    }
    if ([string]::IsNullOrWhiteSpace($tapAdapterName) -or $tapAdapterName -match '["\r\n]') {
        Write-Warning 'Enter a non-empty adapter name without quotation marks or line breaks.'
        continue
    }
    $selectedTapAdapter = $tapAdapters | Where-Object { $_.Name -eq $tapAdapterName } | Select-Object -First 1
    if (-not $selectedTapAdapter) {
        Write-Warning "'$tapAdapterName' is not one of the detected TAP-Windows adapter names. Enter the exact name shown above."
        continue
    }
    break
}
[System.IO.File]::WriteAllText($adapterNamePath, $tapAdapterName + [Environment]::NewLine, [System.Text.Encoding]::ASCII)

foreach ($file in @('ca.crt', 'server.crt', 'server.key', 'tls-crypt.key')) {
    $sourcePath = Join-Path $ServerDir $file
    if ((Get-Item -LiteralPath $sourcePath).Length -eq 0) { throw "Source file is empty: $sourcePath" }
    Copy-Item -Path $sourcePath -Destination (Join-Path $configDir $file) -Force
}
$tlsCryptPath = Join-Path $configDir 'tls-crypt.key'
$tlsCryptText = Get-Content -LiteralPath $tlsCryptPath -Raw
$hexKeyLines = @([regex]::Matches($tlsCryptText, '(?m)^[0-9a-fA-F]{32}\s*$'))
if ($tlsCryptText -notmatch '(?m)^-----BEGIN OpenVPN Static key V1-----\s*$' -or
    $tlsCryptText -notmatch '(?m)^-----END OpenVPN Static key V1-----\s*$' -or
    $hexKeyLines.Count -ne 16) {
    throw "The copied tls-crypt.key is not a valid 2048-bit OpenVPN Static key V1 file: $tlsCryptPath"
}
if (Test-Path (Join-Path $ServerDir 'crl.pem')) {
    Copy-Item (Join-Path $ServerDir 'crl.pem') (Join-Path $configDir 'crl.pem') -Force
}
$sourceCcd = Join-Path $ServerDir 'ccd'
if (Test-Path $sourceCcd) {
    Get-ChildItem -Path $sourceCcd -File | ForEach-Object { Copy-Item $_.FullName $ccdTarget -Force }
}

$serverText = Get-Content -Path (Join-Path $ServerDir 'server.ovpn') -Raw
# pull-filter is client-only; remove stale copies from server configs.
$serverText = [regex]::Replace($serverText, '(?m)^[ \t]*pull-filter[ \t]+.*(?:\r?\n|$)', '')
$statusPath = (Join-Path $openVpnLogDir 'openvpn-status.log').Replace('\','/')
$statusLine = 'status "' + $statusPath + '"'
if ([regex]::IsMatch($serverText, '(?m)^[ \t]*status[ \t]+.*$')) {
    $serverText = [regex]::Replace($serverText, '(?m)^[ \t]*status[ \t]+.*$', [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $statusLine })
}
else {
    $serverText += "`r`n$statusLine`r`n"
}
# Keep the generated server.ovpn portable. Add the Windows-specific dev-node
# only to the deployed copy so the Linux installer remains unaffected.
$serverText = [regex]::Replace($serverText, '(?m)^[ \t]*dev-node[ \t]+.*(?:\r?\n|$)', '')
# Use absolute credential paths so the service cannot resolve tls-crypt.key
# relative to an unexpected working directory.
$credentialFiles = @(
    [pscustomobject]@{ Directive = 'ca'; FileName = 'ca.crt' }
    [pscustomobject]@{ Directive = 'cert'; FileName = 'server.crt' }
    [pscustomobject]@{ Directive = 'key'; FileName = 'server.key' }
    [pscustomobject]@{ Directive = 'tls-crypt'; FileName = 'tls-crypt.key' }
)
foreach ($credential in $credentialFiles) {
    $directive = $credential.Directive
    $fileName = $credential.FileName
    $absolutePath = (Join-Path $configDir $fileName).Replace('\', '/')
    $pattern = '(?m)^[ \t]*' + [regex]::Escape($directive) + '[ \t]+.*$'
    if (-not [regex]::IsMatch($serverText, $pattern)) { throw "Generated server.ovpn is missing the '$directive' directive." }
    $replacementLine = $directive + ' "' + $absolutePath + '"'
    $serverText = [regex]::Replace($serverText, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $replacementLine })
}
$devTunMatch = [regex]::Match($serverText, '(?m)^[ \t]*dev[ \t]+tun[ \t]*$')
if (-not $devTunMatch.Success) { throw 'The generated server.ovpn does not contain the expected "dev tun" directive.' }
$devNodeDirective = 'dev-node "' + $tapAdapterName + '"'
$serverText = $serverText.Insert($devTunMatch.Index + $devTunMatch.Length, "`r`n$devNodeDirective")
$serverText = "cd `"$($configDir.Replace('\','/'))`"`r`n" + $serverText
$serverConfigPath = Join-Path $configDir 'server.ovpn'
if (Test-Path $serverConfigPath) {
    $backup = "$serverConfigPath.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Copy-Item $serverConfigPath $backup -Force
    Write-Host "Existing config backed up to $backup"
}
[System.IO.File]::WriteAllText($serverConfigPath, $serverText, [System.Text.Encoding]::ASCII)

# OpenVPN 2.7 runs the daemon as the virtual service account. Explicitly grant
# it runtime read access; copied files do not reliably inherit this ACE from MSI.
$serviceAccount = 'NT SERVICE\OpenVPNService'
$icacls = Join-Path $env:SystemRoot 'System32\icacls.exe'
& $icacls $configDir '/grant' "${serviceAccount}:(RX)" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Could not grant OpenVPNService traversal access to $configDir" }
& $icacls $configDir '/grant' "${serviceAccount}:(OI)(CI)(R)" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Could not grant OpenVPNService inherited read access in $configDir" }
& $icacls $ccdTarget '/grant' "${serviceAccount}:(RX)" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Could not grant OpenVPNService traversal access to $ccdTarget" }
& $icacls $ccdTarget '/grant' "${serviceAccount}:(OI)(CI)(R)" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Could not grant OpenVPNService inherited read access in $ccdTarget" }
foreach ($runtimeFile in @('server.ovpn', 'ca.crt', 'server.crt', 'server.key', 'tls-crypt.key')) {
    $runtimePath = Join-Path $configDir $runtimeFile
    & $icacls $runtimePath '/grant' "${serviceAccount}:(R)" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not grant OpenVPNService read access to $runtimePath" }
}
Get-ChildItem -Path $ccdTarget -File -ErrorAction SilentlyContinue | ForEach-Object {
    & $icacls $_.FullName '/grant' "${serviceAccount}:(R)" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not grant OpenVPNService read access to CCD file $($_.FullName)" }
}
# Keep private keys inaccessible to ordinary users while allowing the service to read them.
foreach ($secretFile in @('server.key', 'tls-crypt.key')) {
    $secretPath = Join-Path $configDir $secretFile
    & $icacls $secretPath '/inheritance:r' '/grant:r' '*S-1-5-18:F' '*S-1-5-32-544:F' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not restrict ACLs on $secretPath" }
    & $icacls $secretPath '/grant' "${serviceAccount}:(R)" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not grant OpenVPNService read access to $secretPath" }
}
# OpenVPN's configured log directory must be writable by its service identity.
& $icacls $openVpnLogDir '/grant' "${serviceAccount}:(M)" "${serviceAccount}:(OI)(CI)(M)" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Could not grant OpenVPNService modify access to log directory $openVpnLogDir" }

# Allow the OpenVPN listener through Windows Firewall.
$portLine = Select-String -Path $serverConfigPath -Pattern '^port\s+(\d+)' | Select-Object -First 1
if (-not $portLine) { throw 'No port directive in server config.' }
$serverPort = [int]$portLine.Matches[0].Groups[1].Value
$ruleName = "OpenVPN Server UDP $serverPort"
Get-NetFirewallRule -DisplayName 'OpenVPN Server UDP *' -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow -Protocol UDP -LocalPort $serverPort -Profile Any | Out-Null

Set-Service -Name 'OpenVPNService' -StartupType Automatic
$openVpnStartTime = Get-Date
if ((Get-Service -Name 'OpenVPNService').Status -eq 'Running') {
    Restart-Service -Name 'OpenVPNService' -Force
} else {
    Start-Service -Name 'OpenVPNService'
}
$service = Get-Service -Name 'OpenVPNService'
Write-Host ''
Write-Host 'Waiting for OpenVPN to initialize the server tunnel adapter...' -ForegroundColor Cyan
Write-Host 'The service can be Running before the VPN interface is ready.' -ForegroundColor DarkGray

# Wait for the OpenVPN daemon itself to initialize, not for a client to connect
# and not for one exact address to appear in Get-NetIPAddress. A server-side
# tunnel interface is configured during daemon startup; client arrival is not
# the readiness signal needed for NetworkCategory configuration.
$daemonInitialized = $false
$daemonErrorFound = $false
$deadline = (Get-Date).AddSeconds(20)
$waitCounter = 0
Write-Host ''
Write-Host 'Waiting for the OpenVPN server process to initialize (no client connection needed)...' -ForegroundColor Cyan
Write-Host 'Checking server.log for "Initialization Sequence Completed".' -ForegroundColor DarkGray

do {
    if (Test-Path $openVpnLog) {
        $logInfo = Get-Item -LiteralPath $openVpnLog -ErrorAction SilentlyContinue
        if ($logInfo -and $logInfo.LastWriteTime -ge $openVpnStartTime.AddSeconds(-2)) {
            $recentLines = @(Get-Content -LiteralPath $openVpnLog -Tail 200 -ErrorAction SilentlyContinue | Where-Object {
                if ($_ -match '^(?<stamp>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})') {
                    try {
                        [datetime]::ParseExact($Matches.stamp, 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture) -ge $openVpnStartTime.AddSeconds(-2)
                    } catch { $false }
                } else { $false }
            })
            $recentLogText = $recentLines -join "`n"
            if ($recentLogText -match 'Initialization Sequence Completed') {
                $daemonInitialized = $true
                break
            }
            if ($recentLogText -match '(?im)(Options error:|Exiting due to fatal error|Cannot load|FATAL:|OpenSSL: error:|Cannot pre-load)') {
                $daemonErrorFound = $true
                break
            }
        }
    }

    $waitCounter++
    if (($waitCounter % 5) -eq 0) {
        Write-Host ("  Still waiting for daemon initialization... {0}s / 20s" -f $waitCounter) -ForegroundColor DarkGray
    }
    Start-Sleep -Seconds 1
} while ((Get-Date) -lt $deadline)

if ($daemonInitialized) {
    Write-Host 'OpenVPN daemon initialized successfully.' -ForegroundColor Green

    $selectedTapAdapter = Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq $tapAdapterName -and $_.InterfaceDescription -match '(?i)TAP[- ]Windows' } |
        Select-Object -First 1

    if (-not $selectedTapAdapter) {
        Write-Warning "OpenVPN initialized, but the selected TAP adapter '$tapAdapterName' is not currently visible to Get-NetAdapter."
    }
    else {
        # Windows may take a moment to publish the connection profile after
        # OpenVPN opens/configures the TAP device. Match by the chosen alias.
        $vpnProfile = $null
        $profileDeadline = (Get-Date).AddSeconds(5)
        do {
            $vpnProfile = Get-NetConnectionProfile -InterfaceAlias $tapAdapterName -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($vpnProfile) { break }
            Start-Sleep -Seconds 1
        } while ((Get-Date) -lt $profileDeadline)

        if ($vpnProfile) {
            if ($vpnProfile.NetworkCategory -eq 'DomainAuthenticated') {
                Write-Host "OpenVPN TAP adapter '$tapAdapterName': DomainAuthenticated (managed by domain policy)." -ForegroundColor Yellow
            }
            else {
                if ($vpnProfile.NetworkCategory -ne 'Private') {
                    Set-NetConnectionProfile -InterfaceAlias $tapAdapterName -NetworkCategory Private -ErrorAction Stop
                }
                Write-Host "OpenVPN TAP adapter '$tapAdapterName' network profile: Private." -ForegroundColor Green
            }
        }
        else {
            $adapterAddresses = @(Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $selectedTapAdapter.ifIndex -ErrorAction SilentlyContinue |
                ForEach-Object { '{0}/{1}' -f $_.IPAddress, $_.PrefixLength })
            $addressSummary = if ($adapterAddresses.Count -gt 0) { $adapterAddresses -join ', ' } else { '(no IPv4 address reported)' }
            Write-Warning "OpenVPN initialized, but Windows has not exposed a connection profile for '$tapAdapterName' yet. This is not waiting for a phone/client connection. Adapter status: $($selectedTapAdapter.Status); IPv4: $addressSummary."
            Write-Host 'Current TAP profiles:' -ForegroundColor Yellow
            Get-NetConnectionProfile -ErrorAction SilentlyContinue | Format-Table InterfaceAlias, NetworkCategory, IPv4Connectivity -AutoSize
            Write-Host 'Adapter details:' -ForegroundColor Yellow
            Get-NetAdapter -Name $tapAdapterName -ErrorAction SilentlyContinue | Format-List Name, InterfaceDescription, Status, ifIndex
            Write-Host 'You can retry the profile change later with:' -ForegroundColor Yellow
            Write-Host "Set-NetConnectionProfile -InterfaceAlias '$tapAdapterName' -NetworkCategory Private"
        }
    }
}
else {
    if ($daemonErrorFound) {
        Write-Warning 'OpenVPN server.log reports a startup error. The tunnel adapter profile was not changed.'
    }
    else {
        Write-Warning 'No fresh "Initialization Sequence Completed" marker appeared within 20 seconds. The tunnel adapter profile was not changed.'
    }
    if (Test-Path $openVpnLog) {
        Write-Host 'Last 40 lines of server.log:' -ForegroundColor Yellow
        Get-Content $openVpnLog -Tail 40
    }
    else {
        Write-Warning "OpenVPN log not found at $openVpnLog"
    }
    Write-Host "Full log: $openVpnLog" -ForegroundColor Yellow
}

Write-Host ''
if (Test-Path $openVpnLog) {
    $logText = Get-Content $openVpnLog -Raw -ErrorAction SilentlyContinue
    if ($logText -match 'Initialization Sequence Completed') {
        Write-Host 'OpenVPN daemon: Initialization Sequence Completed (server initialized).' -ForegroundColor Green
    }
    elseif ($logText -match '(?im)^.*(Options error|ERROR:|Exiting due to fatal error|Cannot load|failed).*') {
        Write-Warning 'OpenVPN log contains an error; review server.log before assuming the VPN is operational.'
    }
    else {
        Write-Host 'OpenVPN daemon: no Initialization Sequence Completed marker found yet.' -ForegroundColor Yellow
    }
}
Write-Host "OpenVPN system service status: $($service.Status)" -ForegroundColor Green
Write-Host "Config: $serverConfigPath"
Write-Host "Logs: $openVpnLogDir"
Write-Host 'Startup type: Automatic (system service; does not depend on a user logon).'
Write-Host ''
Write-Warning ('Router step still required: forward UDP {0} to this PC''s LAN IPv4 address. Reserve that LAN address in DHCP.' -f $serverPort)
Write-Host 'CA private key intentionally not installed: server runtime uses ca.crt (public), not ca.key (signing key).' -ForegroundColor DarkGray
if ($service.Status -ne 'Running') {
    Write-Warning 'The service did not remain running. Inspect the OpenVPN log directory and Windows Event Viewer > Application.'
}
