#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ServerName,
    [string]$CommonName,
    [switch]$RefreshExisting
)

$ErrorActionPreference = 'Stop'
$KitRoot = Join-Path $PSScriptRoot 'OpenVPN-VPN'
$ServersRoot = Join-Path $KitRoot 'servers'
$EasyRSAInstall = Join-Path $KitRoot 'easy-rsa'

function Write-Info([string]$Message) { Write-Host "[+] $Message" -ForegroundColor Cyan }
function Write-Warn([string]$Message) { Write-Host "[!] $Message" -ForegroundColor Yellow }
function Test-ServerId([string]$Value) { return ($Value -match '^[a-zA-Z0-9][a-zA-Z0-9_-]{0,31}$') }
function ConvertTo-IPv4Number([string]$Address) {
    $bytes = ([System.Net.IPAddress]::Parse($Address)).GetAddressBytes()
    return (([long]$bytes[0] * 16777216) + ([long]$bytes[1] * 65536) + ([long]$bytes[2] * 256) + [long]$bytes[3])
}
function ConvertFrom-IPv4Number([long]$Value) {
    $bytes = [byte[]]@(
        [int](($Value -shr 24) -band 255),
        [int](($Value -shr 16) -band 255),
        [int](($Value -shr 8) -band 255),
        [int]($Value -band 255)
    )
    return ([System.Net.IPAddress]::new($bytes)).ToString()
}
function ConvertFrom-SecureStringToPlainText([Security.SecureString]$SecureValue) {
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureValue)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
}
function ConvertTo-PosixArgument([string]$Value) {
    return "'" + $Value.Replace("'", "'\''") + "'"
}

# Load available server configurations created by New-OpenVPN-Server.ps1.
$available = @()
if (Test-Path -LiteralPath $ServersRoot) {
    $available = @(Get-ChildItem -LiteralPath $ServersRoot -Directory | Where-Object {
        (Test-Path (Join-Path $_.FullName 'server-settings.json')) -and
        (Test-Path (Join-Path $_.FullName 'server\server.ovpn')) -and
        (Test-Path (Join-Path $_.FullName 'pki\ca.crt')) -and
        (Test-Path (Join-Path $_.FullName 'pki\private\ca.key'))
    } | Sort-Object Name)
}
if ($available.Count -eq 0) {
    throw "No usable server configurations found under '$ServersRoot'. Run New-OpenVPN-Server.ps1 first."
}

$selected = $null
if (-not [string]::IsNullOrWhiteSpace($ServerName)) {
    if (-not (Test-ServerId $ServerName)) { throw 'Invalid server name.' }
    $selected = $available | Where-Object { $_.Name -eq $ServerName } | Select-Object -First 1
    if (-not $selected) { throw "Server configuration '$ServerName' was not found. Available: $($available.Name -join ', ')" }
}
elseif ($available.Count -eq 1) {
    $selected = $available[0]
    Write-Host "Using the only available server configuration: $($selected.Name)" -ForegroundColor Cyan
}
else {
    Write-Host 'Available server configurations:' -ForegroundColor Cyan
    for ($i = 0; $i -lt $available.Count; $i++) {
        $infoPath = Join-Path $available[$i].FullName 'server-settings.json'
        $info = Get-Content -LiteralPath $infoPath -Raw | ConvertFrom-Json
        $endpointPath = Join-Path $available[$i].FullName 'server-endpoint.txt'
        $endpoint = if (Test-Path $endpointPath) { (Get-Content $endpointPath -Raw).Trim() } else { '(endpoint missing)' }
        Write-Host ("  {0}. {1}  [{2}/{3}, UDP {4}]  {5}" -f ($i + 1), $available[$i].Name, $info.Network, $info.Prefix, $info.Port, $endpoint)
    }
    while ($true) {
        $choice = Read-Host 'Select server number'
        $index = 0
        if ([int]::TryParse($choice, [ref]$index) -and $index -ge 1 -and $index -le $available.Count) {
            $selected = $available[$index - 1]
            break
        }
        Write-Warn "Enter a number from 1 to $($available.Count)."
    }
}

$ServerName = $selected.Name
$ServerHome = $selected.FullName
$PkiDir = Join-Path $ServerHome 'pki'
$ServerDir = Join-Path $ServerHome 'server'
$CcdDir = Join-Path $ServerDir 'ccd'
$ClientsDir = Join-Path $ServerHome 'clients'
$PackagesDir = Join-Path $ServerHome 'client-packages'
$settingsPath = Join-Path $ServerHome 'server-settings.json'
$endpointPath = Join-Path $ServerHome 'server-endpoint.txt'
$settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
$endpoint = if (Test-Path $endpointPath) { (Get-Content -LiteralPath $endpointPath -Raw).Trim() } else { '' }
if ([string]::IsNullOrWhiteSpace($endpoint)) { throw "Server endpoint is missing: $endpointPath. Rerun New-OpenVPN-Server.ps1 for this server." }

$networkAddress = [System.Net.IPAddress]::Parse([string]$settings.Network)
if ($networkAddress.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { throw 'Server settings contain an invalid IPv4 network.' }
$prefix = [int]$settings.Prefix
$port = [int]$settings.Port
if ($prefix -lt 16 -or $prefix -gt 30) { throw "Unsupported prefix in server-settings.json: /$prefix" }
if ($port -lt 1 -or $port -gt 65535) { throw "Invalid UDP port in server-settings.json: $port" }
$networkBase = ConvertTo-IPv4Number $networkAddress.ToString()
$totalAddresses = [int][Math]::Pow(2, 32 - $prefix)
$maxClientOffset = $totalAddresses - 2
$maskBytes = [byte[]]@(0, 0, 0, 0)
for ($bit = 0; $bit -lt $prefix; $bit++) {
    $octet = [int][Math]::Floor($bit / 8)
    $shift = 7 - ($bit % 8)
    $maskBytes[$octet] = [byte]($maskBytes[$octet] -bor (1 -shl $shift))
}
$mask = ([System.Net.IPAddress]::new($maskBytes)).ToString()

New-Item -ItemType Directory -Path $CcdDir, $ClientsDir, $PackagesDir -Force | Out-Null
$used = @{}
Get-ChildItem -LiteralPath $CcdDir -File -ErrorAction SilentlyContinue | ForEach-Object {
    $content = Get-Content -LiteralPath $_.FullName -Raw
    if ($content -match '(?m)^ifconfig-push\s+((?:\d{1,3}\.){3}\d{1,3})\s+') {
        try {
            $offset = (ConvertTo-IPv4Number $Matches[1]) - $networkBase
            if ($offset -ge 2 -and $offset -le $maxClientOffset) { $used[[int]$offset] = $true }
        }
        catch { }
    }
}
$vpnAddress = $null
if ($RefreshExisting) {
    if ([string]::IsNullOrWhiteSpace($CommonName)) { $CommonName = Read-Host 'Existing device/certificate name to refresh' }
    $CommonName = $CommonName.Trim().ToLowerInvariant()
    if ($CommonName -notmatch '^[a-z0-9][a-z0-9_-]{0,31}$') { throw 'Invalid device name. Use 1-32 lowercase letters, digits, underscore or hyphen.' }
    $ccdPath = Join-Path $CcdDir $CommonName
    $existingCert = Join-Path $PkiDir "issued\$CommonName.crt"
    $existingKey = Join-Path $PkiDir "private\$CommonName.key"
    if (-not (Test-Path $ccdPath) -or -not (Test-Path $existingCert) -or -not (Test-Path $existingKey)) {
        throw "Cannot refresh '$CommonName': the existing CCD entry, certificate, or private key is missing."
    }
    $indexPath = Join-Path $PkiDir 'index.txt'
    if (Test-Path $indexPath) {
        $revokedEntry = Get-Content -LiteralPath $indexPath | Where-Object {
            $_ -match '^R\t' -and $_.Contains("/CN=$CommonName")
        } | Select-Object -First 1
        if ($revokedEntry) { throw "Certificate '$CommonName' is revoked. A replacement must use a new device name and certificate." }
    }
    $ccdText = Get-Content -LiteralPath $ccdPath -Raw
    if ($ccdText -notmatch '(?m)^ifconfig-push\s+((?:\d{1,3}\.){3}\d{1,3})\s+') {
        throw "CCD entry for '$CommonName' does not contain an ifconfig-push address."
    }
    $vpnAddress = $Matches[1]
    $existingOffset = (ConvertTo-IPv4Number $vpnAddress) - $networkBase
    if ($existingOffset -lt 2 -or $existingOffset -gt $maxClientOffset) {
        throw "Existing address $vpnAddress for '$CommonName' is outside the selected server subnet. Run New-OpenVPN-Server.ps1 to reconcile the server network first."
    }
    Write-Info "Refreshing the existing profile/package for '$CommonName'; its certificate and VPN address will be retained."
}
else {
    $nextOffset = $null
    for ($candidate = 2; $candidate -le $maxClientOffset; $candidate++) {
        if (-not $used.ContainsKey($candidate)) { $nextOffset = $candidate; break }
    }
    if ($null -eq $nextOffset) { throw "No free client addresses remain in $($settings.Network)/$prefix." }
    $vpnAddress = ConvertFrom-IPv4Number ($networkBase + $nextOffset)

    if ([string]::IsNullOrWhiteSpace($CommonName)) {
        $defaultName = if ((Get-ChildItem -LiteralPath $CcdDir -File -ErrorAction SilentlyContinue | Measure-Object).Count -eq 0) { 'phone' } else { 'device' }
        while ($true) {
            $rawName = Read-Host "Device name / certificate name [$defaultName]"
            if ([string]::IsNullOrWhiteSpace($rawName)) { $rawName = $defaultName }
            $CommonName = $rawName.Trim().ToLowerInvariant() -replace '[^a-z0-9_-]+', '-'
            $CommonName = $CommonName.Trim('-')
            if ([string]::IsNullOrWhiteSpace($CommonName) -or $CommonName.Length -gt 32 -or $CommonName -notmatch '^[a-z0-9][a-z0-9_-]*$') {
                Write-Warn 'Use 1-32 characters: a-z, 0-9, underscore or hyphen.'
                continue
            }
            $cert = Join-Path $PkiDir "issued\$CommonName.crt"
            $key = Join-Path $PkiDir "private\$CommonName.key"
            $req = Join-Path $PkiDir "reqs\$CommonName.req"
            $reserved = @('server', 'ca', 'easyrsa-tls') -contains $CommonName
            if ($reserved -or (Test-Path (Join-Path $CcdDir $CommonName)) -or (Test-Path $cert) -or (Test-Path $key) -or (Test-Path $req)) {
                Write-Warn "The name '$CommonName' is already present or reserved. Use a new device name; revoked names are not reused."
                continue
            }
            break
        }
    }
    else {
        $CommonName = $CommonName.Trim().ToLowerInvariant()
        if ($CommonName -notmatch '^[a-z0-9][a-z0-9_-]{0,31}$') { throw 'Invalid device name. Use 1-32 lowercase letters, digits, underscore or hyphen.' }
        if ((Test-Path (Join-Path $CcdDir $CommonName)) -or (Test-Path (Join-Path $PkiDir "issued\$CommonName.crt")) -or
            (Test-Path (Join-Path $PkiDir "private\$CommonName.key")) -or (Test-Path (Join-Path $PkiDir "reqs\$CommonName.req"))) {
            throw "Device name '$CommonName' already exists or is reserved. Client certificates and addresses are not reused."
        }
    }
}

if (-not $RefreshExisting) {
    $startBat = Get-ChildItem -LiteralPath $EasyRSAInstall -Filter 'EasyRSA-Start.bat' -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $startBat) { throw "Easy-RSA is missing under '$EasyRSAInstall'. Run New-OpenVPN-Server.ps1 first." }
    $script:EasyRSAHome = Split-Path -Parent $startBat.FullName
    $shellExe = Join-Path $script:EasyRSAHome 'bin\sh.exe'
    $opensslExe = Join-Path $script:EasyRSAHome 'openssl.exe'
    $caKeyPath = Join-Path $PkiDir 'private\ca.key'
    if (-not (Test-Path $shellExe) -or -not (Test-Path $opensslExe) -or -not (Test-Path $caKeyPath)) {
        throw 'The selected server PKI or Easy-RSA tools are incomplete.'
    }

    $caPassphrase = $null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $secureValue = Read-Host 'Enter the CA passphrase (input is hidden)' -AsSecureString
        $plainValue = ConvertFrom-SecureStringToPlainText $secureValue
        if ([string]::IsNullOrEmpty($plainValue) -or $plainValue -match '[^\x20-\x7E]') {
            Write-Warn 'Use a non-empty passphrase containing printable ASCII characters.'
            continue
        }
        $oldPass = $env:OPENVPN_CA_PASS
        $oldPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $env:OPENVPN_CA_PASS = $plainValue
            $null = & $opensslExe pkey -in $caKeyPath -passin 'env:OPENVPN_CA_PASS' -noout 2>$null
            $validationExit = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $oldPreference
            $env:OPENVPN_CA_PASS = $oldPass
        }
        if ($validationExit -eq 0) { $caPassphrase = $plainValue; break }
        Write-Warn 'That passphrase did not decrypt the selected server CA. Try again.'
    }
    if ($null -eq $caPassphrase) { throw 'Could not unlock the selected server CA after three attempts.' }

    $oldEasyRsa = $env:EASYRSA
    $oldEasyRsaPki = $env:EASYRSA_PKI
    $oldEasyRsaOpenSsl = $env:EASYRSA_OPENSSL
    $oldHome = $env:HOME
    $oldEnv = $env:ENV
    $oldPath = $env:PATH
    $oldPassIn = $env:EASYRSA_PASSIN
    $oldCaPass = $env:OPENVPN_CA_PASS
    Push-Location $script:EasyRSAHome
    try {
        $homePosix = $script:EasyRSAHome.Replace('\', '/')
        $env:EASYRSA = $homePosix
        $env:EASYRSA_PKI = $PkiDir.Replace('\', '/')
        $env:EASYRSA_OPENSSL = $opensslExe.Replace('\', '/')
        $env:HOME = $homePosix
        $env:ENV = '/disable-env'
        $env:PATH = "$($script:EasyRSAHome);$(Join-Path $script:EasyRSAHome 'bin');$oldPath"
        $env:OPENVPN_CA_PASS = $caPassphrase
        $env:EASYRSA_PASSIN = 'env:OPENVPN_CA_PASS'
        if (-not (Test-Path (Join-Path $PkiDir "private\$CommonName.key"))) {
            $quoted = @('./easyrsa', '--noinline', '--batch', 'build-client-full', $CommonName, 'nopass') | ForEach-Object { ConvertTo-PosixArgument ([string]$_) }
            & $shellExe '-c' ($quoted -join ' ')
            if ($LASTEXITCODE -ne 0) { throw "Easy-RSA failed to issue client '$CommonName' (exit $LASTEXITCODE)." }
        }
    }
    finally {
        $env:EASYRSA = $oldEasyRsa
        $env:EASYRSA_PKI = $oldEasyRsaPki
        $env:EASYRSA_OPENSSL = $oldEasyRsaOpenSsl
        $env:HOME = $oldHome
        $env:ENV = $oldEnv
        $env:PATH = $oldPath
        $env:EASYRSA_PASSIN = $oldPassIn
        $env:OPENVPN_CA_PASS = $oldCaPass
        Pop-Location
    }

}

$clientCertPath = Join-Path $PkiDir "issued\$CommonName.crt"
$clientKeyPath = Join-Path $PkiDir "private\$CommonName.key"
foreach ($required in @($clientCertPath, $clientKeyPath, (Join-Path $PkiDir 'ca.crt'), (Join-Path $PkiDir 'private\easyrsa-tls.key'))) {
    if (-not (Test-Path -LiteralPath $required)) { throw "Required client/CA file missing: $required" }
}
if (-not $RefreshExisting) {
    $ccdContent = "ifconfig-push $vpnAddress $mask`r`n"
    [System.IO.File]::WriteAllText((Join-Path $CcdDir $CommonName), $ccdContent, [System.Text.Encoding]::ASCII)
}

$ca = (Get-Content -LiteralPath (Join-Path $PkiDir 'ca.crt') -Raw).Trim()
$cert = (Get-Content -LiteralPath $clientCertPath -Raw).Trim()
$key = (Get-Content -LiteralPath $clientKeyPath -Raw).Trim()
$tlsCrypt = (Get-Content -LiteralPath (Join-Path $PkiDir 'private\easyrsa-tls.key') -Raw).Trim()
$profile = @"
client
dev tun
proto udp
remote $endpoint $port udp
resolv-retry infinite
nobind
persist-tun
remote-cert-tls server
tls-version-min 1.2
data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
auth-nocache
verb 3

<ca>
$ca
</ca>
<cert>
$cert
</cert>
<key>
$key
</key>
<tls-crypt>
$tlsCrypt
</tls-crypt>
"@
$profilePath = Join-Path $ClientsDir "$CommonName.ovpn"
[System.IO.File]::WriteAllText($profilePath, $profile, [System.Text.Encoding]::ASCII)

foreach ($installer in @('Install-OpenVPN-Client-Windows.ps1', 'Install-Windows.cmd', 'install-openvpn-client-linux.sh')) {
    $installerPath = Join-Path $PSScriptRoot $installer
    if (-not (Test-Path -LiteralPath $installerPath -PathType Leaf)) { throw "Client installer missing beside generator: $installerPath" }
}
$packageDir = Join-Path $PackagesDir $CommonName
if (Test-Path -LiteralPath $packageDir) { Remove-Item -LiteralPath $packageDir -Recurse -Force }
New-Item -ItemType Directory -Path $packageDir -Force | Out-Null
Copy-Item -LiteralPath $profilePath -Destination $packageDir -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Install-OpenVPN-Client-Windows.ps1') -Destination $packageDir -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Install-Windows.cmd') -Destination $packageDir -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'install-openvpn-client-linux.sh') -Destination $packageDir -Force
$packageReadme = @"
OPENVPN CLIENT PACKAGE
Device: $CommonName
Server: $ServerName
Assigned VPN address: $vpnAddress

WHAT TO COPY
Copy this ZIP file to the target device. You do not need to copy anything else from the server or the OpenVPN Home Server Kit.

WINDOWS 10/11
1. Extract the ZIP (right-click > Extract All).
2. Open the extracted folder.
3. Double-click Install-Windows.cmd and approve the UAC prompt.
   It opens an elevated PowerShell window and runs the installer.

LINUX
1. Extract the ZIP.
2. Open a terminal in the extracted folder and run:
   sudo bash ./install-openvpn-client-linux.sh

PACKAGE CONTENTS
- This device's self-contained .ovpn profile.
- Windows installer and one-click elevated launcher.
- Linux installer.
- These instructions.

No server configuration, server private key, CA private key, or Easy-RSA database is included.

SECURITY
The .ovpn profile contains this device's private key, client certificate, public CA certificate, and shared TLS control-channel key. Treat the ZIP as a secret, transfer it securely, and do not reuse it on another device.
"@
[System.IO.File]::WriteAllText((Join-Path $packageDir 'INSTALL.txt'), $packageReadme, [System.Text.Encoding]::UTF8)
$packageZip = Join-Path $PackagesDir "$CommonName.zip"
if (Test-Path -LiteralPath $packageZip) { Remove-Item -LiteralPath $packageZip -Force }
Compress-Archive -Path (Join-Path $packageDir '*') -DestinationPath $packageZip -CompressionLevel Optimal

Write-Host ''
Write-Host "Client '$CommonName' generated for server '$ServerName'." -ForegroundColor Green
Write-Host "Assigned VPN address: $vpnAddress"
Write-Host "Client package: $packageZip"
Write-Host ''
Write-Host 'CLIENT INSTALLATION — copy only the ZIP above to the target device.' -ForegroundColor Cyan
Write-Host 'Windows: extract it, then double-click Install-Windows.cmd and approve the UAC prompt.'
Write-Host 'Linux: extract it, then run: sudo bash ./install-openvpn-client-linux.sh'
Write-Host 'No other files from the server or the Home Server Kit are required.'
Write-Warn 'The ZIP contains this device private key. Transfer it securely and do not reuse it.'
if (-not $RefreshExisting) { Write-Warn 'Rerun the selected server installer to deploy the new CCD assignment before connecting.' }
