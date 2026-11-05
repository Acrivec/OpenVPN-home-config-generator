#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ServerDir
)

$ErrorActionPreference = 'Stop'

# Windows server mode uses OpenVPN 2.7+ DCO. OpenVPN itself is never
# downloaded, upgraded, or installed by this script.
$minimumOpenVPNVersion = [version]'2.7.0'
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
    $serversRoot = Join-Path $PSScriptRoot 'OpenVPN-VPN\servers'
    $available = @()
    if (Test-Path -LiteralPath $serversRoot) {
        $available = @(Get-ChildItem -LiteralPath $serversRoot -Directory | Where-Object {
            Test-Path (Join-Path $_.FullName 'server\server.ovpn')
        } | Sort-Object Name)
    }
    if ($available.Count -eq 1) {
        $ServerDir = Join-Path $available[0].FullName 'server'
    }
    elseif ($available.Count -gt 1) {
        Write-Host 'Available generated server bundles:' -ForegroundColor Cyan
        for ($i = 0; $i -lt $available.Count; $i++) { Write-Host ("  {0}. {1}" -f ($i + 1), $available[$i].Name) }
        while ($true) {
            $choice = Read-Host 'Select server bundle number'
            $selectedIndex = 0
            if ([int]::TryParse($choice, [ref]$selectedIndex) -and $selectedIndex -ge 1 -and $selectedIndex -le $available.Count) {
                $ServerDir = Join-Path $available[$selectedIndex - 1].FullName 'server'
                break
            }
            Write-Warning "Enter a number from 1 to $($available.Count)."
        }
    }
    else {
        $ServerDir = Join-Path $PSScriptRoot 'OpenVPN-VPN\server'
        if (-not (Test-Path (Join-Path $ServerDir 'server.ovpn'))) { $ServerDir = Join-Path $PSScriptRoot 'server' }
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
    throw "OpenVPN was not found at '$openVpnExe'. This script does not download or install OpenVPN. Install OpenVPN Community 2.7.0 or newer with OpenVPNService and the default network-driver components, then rerun this script."
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
    throw "OpenVPN $installedVersion is too old for this kit. OpenVPN 2.7.0 or newer is required for Windows server-mode DCO. Update OpenVPN manually, then rerun this script. This script will not download or install an MSI."
}
if ($installedVersion -lt $recommendedOpenVPNVersion) {
    Write-Warning "Detected OpenVPN $installedVersion. The current recommended release is $recommendedOpenVPNVersion. Windows server-mode DCO is available from OpenVPN 2.7.0. Continuing without an automatic upgrade. Update OpenVPN manually when convenient."
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

# Do not pin a Windows adapter with dev-node. OpenVPN 2.7 selects ovpn-dco
# by default and falls back to tap-windows6 when the configuration requires it.
# Remove the legacy per-machine adapter-name cache from earlier kit versions.
$legacyAdapterNamePath = Join-Path $configDir 'tap-adapter-name.txt'
if (Test-Path -LiteralPath $legacyAdapterNamePath) {
    Remove-Item -LiteralPath $legacyAdapterNamePath -Force
}

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
# Keep the runtime config portable and let OpenVPN 2.7 select its driver.
# Strip legacy directives from bundles generated by earlier kit versions.
$serverText = [regex]::Replace($serverText, '(?m)^[ \t]*dev-node[ \t]+.*(?:\r?\n|$)', '')
$serverText = [regex]::Replace($serverText, '(?m)^[ \t]*disable-dco[ \t]*(?:\r?\n|$)', '')
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

# With DCO, client-to-client packets are forwarded by the Windows IP stack.
# The legacy client-to-client directive remains in the config for TAP fallback,
# but DCO requires IP routing plus the Routing and Remote Access service.
$routingRebootRequired = $false
$clientToClientEnabled = [regex]::IsMatch($serverText, '(?m)^[ \t]*client-to-client[ \t]*(?:#.*)?$')
if ($clientToClientEnabled) {
    $tcpipParameters = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters'
    try {
        $ipEnableRouter = (Get-ItemProperty -Path $tcpipParameters -Name IPEnableRouter -ErrorAction SilentlyContinue).IPEnableRouter
        if ([int]$ipEnableRouter -ne 1) {
            New-ItemProperty -Path $tcpipParameters -Name IPEnableRouter -PropertyType DWord -Value 1 -Force | Out-Null
            $routingRebootRequired = $true
            Write-Host 'Enabled Windows IP forwarding for DCO client-to-client routing.' -ForegroundColor Green
        }
    }
    catch {
        Write-Warning "Could not enable Windows IP forwarding: $($_.Exception.Message). VPN clients may not be able to reach one another while DCO is active."
    }

    try {
        $remoteAccess = Get-Service -Name 'RemoteAccess' -ErrorAction Stop
        $remoteAccessCim = Get-CimInstance -ClassName Win32_Service -Filter "Name='RemoteAccess'" -ErrorAction Stop
        if ($remoteAccessCim.StartMode -ne 'Auto') {
            Set-Service -Name 'RemoteAccess' -StartupType Automatic -ErrorAction Stop
            $routingRebootRequired = $true
            Write-Host 'Set Routing and Remote Access service to Automatic for DCO forwarding.' -ForegroundColor Green
        }
    }
    catch {
        Write-Warning "Could not configure the Windows Routing and Remote Access service: $($_.Exception.Message). VPN clients may not be able to reach one another while DCO is active."
    }
}

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

    # Match the live VPN interface by the server address derived from the
    # generated server subnet. This works with DCO's on-demand adapter and
    # with the TAP-Windows fallback, without assuming an adapter alias.
    $serverDirective = [regex]::Match(
        $serverText,
        '(?m)^[ \t]*server[ \t]+(?<network>(?:\d{1,3}\.){3}\d{1,3})[ \t]+(?<mask>(?:\d{1,3}\.){3}\d{1,3})(?:[ \t]+nopool)?[ \t]*$'
    )
    if (-not $serverDirective.Success) {
        Write-Warning 'OpenVPN initialized, but the server subnet could not be parsed; the adapter network category was not changed.'
    }
    else {
        $networkBytes = [System.Net.IPAddress]::Parse($serverDirective.Groups['network'].Value).GetAddressBytes()
        # With topology subnet, OpenVPN assigns the first usable address to the server.
        $carry = 1
        for ($byteIndex = 3; $byteIndex -ge 0 -and $carry -eq 1; $byteIndex--) {
            $nextValue = [int]$networkBytes[$byteIndex] + 1
            if ($nextValue -gt 255) {
                $networkBytes[$byteIndex] = [byte]0
            }
            else {
                $networkBytes[$byteIndex] = [byte]$nextValue
                $carry = 0
            }
        }
        if ($carry -eq 1) { throw 'Could not calculate the server tunnel IPv4 address from the configured subnet.' }
        $serverTunnelAddress = ([System.Net.IPAddress]::new([byte[]]$networkBytes)).ToString()
        Write-Host "Looking for the VPN interface by its server tunnel address ($serverTunnelAddress)..." -ForegroundColor Cyan

        $serverTunnelIp = $null
        $vpnAdapter = $null
        $adapterDeadline = (Get-Date).AddSeconds(15)
        do {
            $serverTunnelIp = Get-NetIPAddress -AddressFamily IPv4 -IPAddress $serverTunnelAddress -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($serverTunnelIp) {
                $vpnAdapter = Get-NetAdapter -InterfaceIndex $serverTunnelIp.InterfaceIndex -IncludeHidden -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($vpnAdapter) { break }
            }
            Start-Sleep -Seconds 1
        } while ((Get-Date) -lt $adapterDeadline)

        if (-not $serverTunnelIp -or -not $vpnAdapter) {
            Write-Warning "OpenVPN initialized, but Windows has not exposed an adapter with server tunnel address $serverTunnelAddress. No network category was changed."
            Write-Host 'Current IPv4 addresses:' -ForegroundColor Yellow
            Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Format-Table IPAddress, InterfaceAlias, InterfaceIndex, PrefixLength -AutoSize
        }
        else {
            $vpnProfile = Get-NetConnectionProfile -InterfaceIndex $vpnAdapter.ifIndex -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($vpnProfile) {
                if ($vpnProfile.NetworkCategory -eq 'DomainAuthenticated') {
                    Write-Host "VPN adapter '$($vpnAdapter.Name)' ($serverTunnelAddress): DomainAuthenticated (managed by domain policy)." -ForegroundColor Yellow
                }
                else {
                    if ($vpnProfile.NetworkCategory -ne 'Private') {
                        Set-NetConnectionProfile -InterfaceIndex $vpnAdapter.ifIndex -NetworkCategory Private -ErrorAction Stop
                    }
                    Write-Host "VPN adapter '$($vpnAdapter.Name)' ($serverTunnelAddress) network profile: Private." -ForegroundColor Green
                }
            }
            else {
                Write-Warning "The VPN adapter '$($vpnAdapter.Name)' has the expected address $serverTunnelAddress, but Windows has not published its connection profile yet."
                Write-Host 'Adapter details:' -ForegroundColor Yellow
                $vpnAdapter | Format-List Name, InterfaceDescription, Status, ifIndex
                Write-Host 'You can retry the profile change later with:' -ForegroundColor Yellow
                Write-Host "Set-NetConnectionProfile -InterfaceIndex $($vpnAdapter.ifIndex) -NetworkCategory Private"
            }
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
if ($routingRebootRequired) {
    Write-Warning 'Windows IP-routing settings changed. Reboot this PC to apply them; DCO client-to-client forwarding may not work until after the reboot.'
}
Write-Host 'CA private key intentionally not installed: server runtime uses ca.crt (public), not ca.key (signing key).' -ForegroundColor DarkGray
if ($service.Status -ne 'Running') {
    Write-Warning 'The service did not remain running. Inspect the OpenVPN log directory and Windows Event Viewer > Application.'
}
