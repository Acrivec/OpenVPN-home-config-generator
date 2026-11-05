#requires -Version 5.1
[CmdletBinding()]
param([string]$ServerName)

$ErrorActionPreference = 'Stop'
$KitRoot = Join-Path $PSScriptRoot 'OpenVPN-VPN'
$ServersRoot = Join-Path $KitRoot 'servers'
$EasyRSAInstall = Join-Path $KitRoot 'easy-rsa'
$EasyRSAUrl = 'https://github.com/OpenVPN/easy-rsa/releases/download/v3.2.7/EasyRSA-3.2.7-win64.zip'
$EasyRSAZipSha256 = '2f20c7523fe37df91c578c35e7fe83301f3687792bb9bd1000d0e407ef70d368'

function Test-ServerId([string]$Value) {
    return ($Value -match '^[a-zA-Z0-9][a-zA-Z0-9_-]{0,31}$')
}

# Migrate the v3-v12 single-server layout without replacing its CA or certificates.
# The Easy-RSA application remains shared; its PKI moves into servers/<id>/pki.
$legacyPki = $null
$legacyStart = Get-ChildItem -Path $EasyRSAInstall -Filter 'EasyRSA-Start.bat' -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
if ($legacyStart) {
    $candidatePki = Join-Path (Split-Path -Parent $legacyStart.FullName) 'pki'
    if (Test-Path (Join-Path $candidatePki 'private\ca.key')) { $legacyPki = $candidatePki }
}
$configuredServers = @()
if (Test-Path -LiteralPath $ServersRoot) {
    $configuredServers = @(Get-ChildItem -LiteralPath $ServersRoot -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path (Join-Path $_.FullName 'server-settings.json') })
}
$legacyLayout = (($legacyPki -or (Test-Path (Join-Path $KitRoot 'server'))) -and $configuredServers.Count -eq 0)
if ($legacyLayout) {
    $ServerName = if ($PSBoundParameters.ContainsKey('ServerName') -and $ServerName) { $ServerName } else { 'default' }
    if (-not (Test-ServerId $ServerName)) { throw 'Server name must be 1-32 characters: letters, digits, underscore or hyphen.' }
    $ServerName = $ServerName.ToLowerInvariant()
    $ServerHome = Join-Path $ServersRoot $ServerName
    New-Item -ItemType Directory -Path $ServerHome -Force | Out-Null
    if ($legacyPki) {
        $newPki = Join-Path $ServerHome 'pki'
        if (-not (Test-Path $newPki)) { Move-Item -LiteralPath $legacyPki -Destination $newPki }
    }
    foreach ($entry in @(
        @{ Old = 'server'; New = 'server' },
        @{ Old = 'clients'; New = 'clients' },
        @{ Old = 'client-packages'; New = 'client-packages' },
        @{ Old = 'server-settings.json'; New = 'server-settings.json' },
        @{ Old = 'server-endpoint.txt'; New = 'server-endpoint.txt' }
    )) {
        $source = Join-Path $KitRoot $entry.Old
        $destination = Join-Path $ServerHome $entry.New
        if ((Test-Path -LiteralPath $source) -and -not (Test-Path -LiteralPath $destination)) {
            Move-Item -LiteralPath $source -Destination $destination
        }
    }
    Write-Host "Migrated the existing single-server data into OpenVPN-VPN\servers\$ServerName without regenerating its CA." -ForegroundColor Green
}
else {
    New-Item -ItemType Directory -Path $ServersRoot -Force | Out-Null
    if ([string]::IsNullOrWhiteSpace($ServerName)) {
        $existing = @(Get-ChildItem -LiteralPath $ServersRoot -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'server-settings.json') } | Sort-Object Name)
        if ($existing.Count -gt 0) {
            Write-Host 'Existing server configurations:' -ForegroundColor Cyan
            foreach ($item in $existing) { Write-Host "  $($item.Name)" }
            Write-Host 'Enter an existing name to update it, or a new name to create another server.' -ForegroundColor DarkGray
        }
        $defaultServerName = if ($existing.Count -eq 0) { 'home' } else { $existing[0].Name }
        $ServerName = Read-Host "Server configuration name [$defaultServerName]"
        if ([string]::IsNullOrWhiteSpace($ServerName)) { $ServerName = $defaultServerName }
    }
    if (-not (Test-ServerId $ServerName)) { throw 'Server name must be 1-32 characters: letters, digits, underscore or hyphen.' }
    $ServerName = $ServerName.ToLowerInvariant()
}

$ServerHome = Join-Path $ServersRoot $ServerName
$Root = $ServerHome
$ServerDir = Join-Path $ServerHome 'server'
$CcdDir = Join-Path $ServerDir 'ccd'
$EndpointFile = Join-Path $ServerHome 'server-endpoint.txt'
$PkiDir = Join-Path $ServerHome 'pki'
$script:EasyRSAHome = $null
$script:CaPassphrase = $null

function Write-Info([string]$Message) { Write-Host "[+] $Message" -ForegroundColor Cyan }
function Write-Warn([string]$Message) { Write-Host "[!] $Message" -ForegroundColor Yellow }

function Get-EasyRSAStart {
    if (Test-Path $EasyRSAInstall) {
        $found = Get-ChildItem -Path $EasyRSAInstall -Filter 'EasyRSA-Start.bat' -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { return $found.FullName }
    }

    New-Item -ItemType Directory -Path $EasyRSAInstall -Force | Out-Null
    $zipPath = Join-Path $Root 'EasyRSA-3.2.7-win64.zip'
    Write-Info 'Downloading Easy-RSA 3.2.7 from the official OpenVPN/easy-rsa release...'
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $EasyRSAUrl -OutFile $zipPath -UseBasicParsing | Out-Null
    $actualHash = (Get-FileHash -Path $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $EasyRSAZipSha256) {
        Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
        throw "Easy-RSA ZIP SHA-256 mismatch. Expected $EasyRSAZipSha256, got $actualHash. Aborting."
    }

    Expand-Archive -Path $zipPath -DestinationPath $EasyRSAInstall -Force
    $found = Get-ChildItem -Path $EasyRSAInstall -Filter 'EasyRSA-Start.bat' -File -Recurse | Select-Object -First 1
    if (-not $found) { throw 'EasyRSA-Start.bat was not found in the downloaded archive.' }
    return $found.FullName
}

function ConvertTo-PosixArgument([string]$Value) {
    # Single-quote each controlled argument so the bundled POSIX shell receives it as one token.
    return "'" + $Value.Replace("'", "'\''") + "'"
}

function ConvertFrom-SecureStringToPlainText([Security.SecureString]$SecureValue) {
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureValue)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
}

function Set-CaPassphrase {
    param(
        [Parameter(Mandatory = $true)][string]$CaKeyPath,
        [Parameter(Mandatory = $true)][string]$OpenSslPath
    )

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $secureValue = Read-Host 'Enter the CA passphrase (input is hidden)' -AsSecureString
        $plainValue = ConvertFrom-SecureStringToPlainText $secureValue
        if ([string]::IsNullOrEmpty($plainValue)) {
            Write-Warn 'The CA passphrase cannot be empty.'
            continue
        }
        if ($plainValue -match '[^\x20-\x7E]') {
            Write-Warn 'Use printable ASCII characters for the CA passphrase. Non-ASCII input can be mis-encoded by the bundled Windows shell/OpenSSL.'
            continue
        }

        $oldPass = $env:OPENVPN_CA_PASS
        $oldErrorAction = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $env:OPENVPN_CA_PASS = $plainValue
            $null = & $OpenSslPath pkey -in $CaKeyPath -passin 'env:OPENVPN_CA_PASS' -noout 2>$null
            $validationExit = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $oldErrorAction
            $env:OPENVPN_CA_PASS = $oldPass
        }

        if ($validationExit -eq 0) {
            $script:CaPassphrase = $plainValue
            return
        }
        Write-Warn 'That passphrase did not decrypt the existing CA key. Try again.'
    }
    throw 'Could not unlock the CA private key after three attempts. No existing PKI files were changed by this check.'
}

function Invoke-EasyRSA([string[]]$ArgumentList) {
    $shellExe = Join-Path $script:EasyRSAHome 'bin\sh.exe'
    $opensslExe = Join-Path $script:EasyRSAHome 'openssl.exe'
    if (-not (Test-Path $shellExe)) { throw "EasyRSA POSIX shell is missing: $shellExe" }
    if (-not (Test-Path $opensslExe)) { throw "EasyRSA's bundled OpenSSL is missing: $opensslExe" }

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
        $env:EASYRSA_PKI = ($PkiDir).Replace('\', '/')
        $env:EASYRSA_OPENSSL = (Join-Path $script:EasyRSAHome 'openssl.exe').Replace('\', '/')
        $env:HOME = $homePosix
        $env:ENV = '/disable-env'
        $env:PATH = "$($script:EasyRSAHome);$(Join-Path $script:EasyRSAHome 'bin');$oldPath"
        if (-not [string]::IsNullOrEmpty($script:CaPassphrase)) {
            $env:OPENVPN_CA_PASS = $script:CaPassphrase
            $env:EASYRSA_PASSIN = 'env:OPENVPN_CA_PASS'
        }
        $quoted = @('./easyrsa', '--noinline') + @($ArgumentList | ForEach-Object { ConvertTo-PosixArgument ([string]$_) })
        $command = $quoted -join ' '
        Write-Info ("Easy-RSA: " + ($ArgumentList -join ' '))
        & $shellExe '-c' $command
        $exitCode = $LASTEXITCODE
        if ($null -eq $exitCode -or $exitCode -ne 0) {
            throw "Easy-RSA command failed with exit code ${exitCode}: $($ArgumentList -join ' ')"
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

function New-TlsCryptKey([string]$Path) {
    $bytes = New-Object byte[] 256
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) }
    finally { $rng.Dispose() }

    $hex = [BitConverter]::ToString($bytes).Replace('-', '').ToLowerInvariant()
    $keyLines = for ($i = 0; $i -lt $hex.Length; $i += 32) { $hex.Substring($i, 32) }
    $contents = @(
        '#',
        '# 2048 bit OpenVPN static key',
        '#',
        '-----BEGIN OpenVPN Static key V1-----'
    ) + $keyLines + @('-----END OpenVPN Static key V1-----')
    [System.IO.File]::WriteAllText($Path, ($contents -join "`r`n") + "`r`n", [System.Text.Encoding]::ASCII)
}

function ConvertTo-IPv4Number([string]$Address) {
    $bytes = ([System.Net.IPAddress]::Parse($Address)).GetAddressBytes()
    return (([long]$bytes[0] * 16777216) + ([long]$bytes[1] * 65536) + ([long]$bytes[2] * 256) + [long]$bytes[3])
}

function Get-IPv4AddressAtOffset([long]$Offset) {
    $value = $script:VpnNetworkBase + $Offset
    $bytes = [byte[]]@(
        [int](($value -shr 24) -band 255),
        [int](($value -shr 16) -band 255),
        [int](($value -shr 8) -band 255),
        [int]($value -band 255)
    )
    return ([System.Net.IPAddress]::new($bytes)).ToString()
}

function Read-VpnNetworkSettings {
    $settingsPath = Join-Path $Root 'server-settings.json'
    $old = @{ Network = '192.168.4.0'; Prefix = 24; Port = 12321 }

    if (Test-Path $settingsPath) {
        try {
            $saved = Get-Content $settingsPath -Raw | ConvertFrom-Json
            if ($saved.Network) { $old.Network = [string]$saved.Network }
            if ($saved.Prefix)  { $old.Prefix = [int]$saved.Prefix }
            if ($saved.Port)    { $old.Port = [int]$saved.Port }
        }
        catch {
            Write-Warn 'Could not read server-settings.json; using defaults.'
        }
    }

    while ($true) {
        $value = Read-Host "VPN network base address [$($old.Network)]"
        if ([string]::IsNullOrWhiteSpace($value)) { $value = $old.Network }

        $parsed = $null
        if ([System.Net.IPAddress]::TryParse($value.Trim(), [ref]$parsed) -and
            $parsed.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
            $network = $parsed.ToString()
            $networkBytes = $parsed.GetAddressBytes()
            break
        }
        Write-Warn 'Enter a valid IPv4 network address.'
    }

    Write-Host ''
    Write-Host 'Subnet capacity (server uses the first usable address; clients use the rest):' -ForegroundColor Yellow
    foreach ($p in 16..30) {
        $total = [int][Math]::Pow(2, 32 - $p)
        $usable = $total - 2
        $clients = $usable - 1
        $maskOctets = @()
        for ($octet = 0; $octet -lt 4; $octet++) {
            $bits = [Math]::Min(8, [Math]::Max(0, $p - (8 * $octet)))
            if ($bits -eq 0) {
                $maskOctets += 0
            }
            else {
                $maskOctets += (256 - [int][Math]::Pow(2, 8 - $bits))
            }
        }
        Write-Host ("  /{0,-2} {1,-15} {2,3} total IPs; {3,3} usable hosts; {4,3} client slots + server" -f
            $p, ($maskOctets -join '.'), $total, $usable, $clients)
    }
    Write-Host '  /31 255.255.255.254   2 point-to-point addresses; not supported by this multi-client server layout.' -ForegroundColor DarkGray
    Write-Host '  /30 is the smallest supported subnet: 1 server + 1 client (not 4 devices).' -ForegroundColor DarkGray
    Write-Host ''

    while ($true) {
        $value = Read-Host "Prefix length /16-/30 [$($old.Prefix)]"
        if ([string]::IsNullOrWhiteSpace($value)) {
            $prefix = $old.Prefix
        }
        else {
            $prefix = 0
            [void][int]::TryParse($value, [ref]$prefix)
        }
        if ($prefix -ge 16 -and $prefix -le 30) { break }
        Write-Warn 'Use a prefix from /16 through /30. /31 is not supported.'
    }

    # Build the subnet mask as four bytes. Avoid 0xFFFFFFFF: PowerShell
    # interprets that literal as signed Int32 (-1) before UInt64 conversion.
    $maskBytes = [byte[]]@(0, 0, 0, 0)
    for ($bit = 0; $bit -lt $prefix; $bit++) {
        $octet = [int][Math]::Floor($bit / 8)
        $shift = 7 - ($bit % 8)
        $maskBytes[$octet] = [byte]($maskBytes[$octet] -bor (1 -shl $shift))
    }
    $normalizedBytes = [byte[]]@(0, 0, 0, 0)
    for ($i = 0; $i -lt 4; $i++) {
        $normalizedBytes[$i] = [byte]($networkBytes[$i] -band $maskBytes[$i])
    }
    $normalizedNetwork = ([System.Net.IPAddress]::new($normalizedBytes)).ToString()
    if ($normalizedNetwork -ne $network) {
        throw "$network is not the network boundary for /$prefix. Use $normalizedNetwork instead."
    }

    while ($true) {
        $value = Read-Host "OpenVPN UDP port [$($old.Port)]"
        if ([string]::IsNullOrWhiteSpace($value)) {
            $port = $old.Port
        }
        else {
            $port = 0
            [void][int]::TryParse($value, [ref]$port)
        }
        if ($port -ge 1 -and $port -le 65535) { break }
        Write-Warn 'Port must be between 1 and 65535.'
    }

    $totalAddresses = [int][Math]::Pow(2, 32 - $prefix)
    $script:VpnNetwork = $network
    $script:VpnPrefix = $prefix
    $script:VpnPort = $port
    $script:VpnMask = ([System.Net.IPAddress]::new($maskBytes)).ToString()
    $script:VpnNetworkBase = ConvertTo-IPv4Number $network
    $script:VpnTotalAddresses = $totalAddresses
    $script:VpnClientCapacity = $totalAddresses - 3

    [System.IO.File]::WriteAllText(
        $settingsPath,
        (@{ Network = $network; Prefix = $prefix; Port = $port } | ConvertTo-Json) + "`r`n",
        [System.Text.Encoding]::UTF8
    )
}

function Get-ServerVpnAddress {
    return (Get-IPv4AddressAtOffset 1)
}

function Get-ClientVpnAddressFromIndex([int]$HostIndex) {
    return (Get-IPv4AddressAtOffset $HostIndex)
}

function Update-ExistingClientAddresses {
    $files = @(Get-ChildItem -Path $CcdDir -File -ErrorAction SilentlyContinue | Sort-Object Name)
    if ($files.Count -gt $script:VpnClientCapacity) {
        throw "The selected subnet supports $($script:VpnClientCapacity) client devices, but $($files.Count) CCD entries already exist. Choose a larger subnet."
    }

    $used = @{}
    $maxHost = $script:VpnTotalAddresses - 2

    foreach ($file in $files) {
        $content = Get-Content $file.FullName -Raw
        $chosenOffset = $null

        if ($content -match '(?m)^ifconfig-push\s+((?:\d{1,3}\.){3}\d{1,3})\s+') {
            try {
                $candidate = (ConvertTo-IPv4Number $Matches[1]) - $script:VpnNetworkBase
                if ($candidate -ge 2 -and $candidate -le $maxHost -and -not $used.ContainsKey([int]$candidate)) {
                    $chosenOffset = [int]$candidate
                }
            }
            catch {
                $chosenOffset = $null
            }
        }

        if ($null -eq $chosenOffset) {
            for ($candidate = 2; $candidate -le $maxHost; $candidate++) {
                if (-not $used.ContainsKey($candidate)) {
                    $chosenOffset = $candidate
                    break
                }
            }
        }

        if ($null -eq $chosenOffset) {
            throw "No free client address remains while updating '$($file.Name)'."
        }

        $used[$chosenOffset] = $true
        $address = Get-ClientVpnAddressFromIndex $chosenOffset
        $newContent = "ifconfig-push $address $script:VpnMask`r`n"
        [System.IO.File]::WriteAllText($file.FullName, $newContent, [System.Text.Encoding]::ASCII)
    }
}

function Read-ServerEndpoint {
    $oldEndpoint = ''
    if (Test-Path $EndpointFile) { $oldEndpoint = (Get-Content $EndpointFile -Raw).Trim() }
    while ($true) {
        if ($oldEndpoint) {
            $value = Read-Host "Public IP or DDNS hostname for clients [$oldEndpoint] (Enter keeps it)"
            if ([string]::IsNullOrWhiteSpace($value)) { return $oldEndpoint }
        }
        else {
            $value = Read-Host 'Public IPv4 address or DDNS hostname of this VPN server'
        }
        $value = $value.Trim()
        if ($value -match '^\d{1,3}(\.\d{1,3}){3}$') {
            $octets = @($value.Split('.') | ForEach-Object { [int]$_ })
            if ($octets.Count -eq 4 -and @($octets | Where-Object { $_ -lt 0 -or $_ -gt 255 }).Count -eq 0) { return $value }
        }
        elseif ($value -match '^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$' -and $value -notmatch '\.\.' -and $value -notmatch '--') {
            return $value
        }
        Write-Warn 'Enter a hostname (example.ddns.net) or valid IPv4 address. Do not include a port or URL scheme.'
    }
}

# Prepare output structure.
New-Item -ItemType Directory -Path $ServerHome, $ServerDir, $CcdDir, $PkiDir -Force | Out-Null
$script:EasyRSAStart = Get-EasyRSAStart
$script:EasyRSAHome = Split-Path -Parent $script:EasyRSAStart
New-Item -ItemType Directory -Path $PkiDir -Force | Out-Null

# Easy-RSA inline files duplicate private keys. This kit builds .ovpn profiles
# itself and uses --noinline, so old generated *.inline files are redundant.
$staleInlineFiles = @(Get-ChildItem -Path (Join-Path $PkiDir 'inline') -Filter '*.inline' -File -Recurse -ErrorAction SilentlyContinue)
if ($staleInlineFiles.Count -gt 0) {
    $staleInlineFiles | Remove-Item -Force
    Write-Info "Removed $($staleInlineFiles.Count) obsolete Easy-RSA inline file(s); the kit does not use them."
}

# Configure the CA identity. Easy-RSA's default encrypted CA private key is retained.

$caCert = Join-Path $PkiDir 'ca.crt'
$caKey = Join-Path $PkiDir 'private\ca.key'
if (-not (Test-Path $caCert)) {
    if (Test-Path $caKey) { throw "The CA private key exists but ca.crt is missing at $PkiDir. Inspect the PKI manually; it was not overwritten." }
    if (-not (Test-Path (Join-Path $PkiDir 'private'))) { Invoke-EasyRSA @('--batch', 'init-pki') }
    Write-Host ''
    Write-Host 'First-time setup: Easy-RSA will create an encrypted Certificate Authority key.' -ForegroundColor Yellow
    Write-Host 'Choose a strong CA passphrase and keep a secure backup of the Easy-RSA pki directory.' -ForegroundColor Yellow
    Invoke-EasyRSA @('build-ca')
}
if (-not (Test-Path $caCert) -or -not (Test-Path $caKey)) {
    throw 'CA certificate or private key is missing. Refusing to create a replacement CA automatically.'
}

Write-Host ''
Write-Host 'Easy-RSA must unlock the encrypted CA key to sign certificates.' -ForegroundColor Yellow
Set-CaPassphrase -CaKeyPath $caKey -OpenSslPath (Join-Path $script:EasyRSAHome 'openssl.exe')

if (-not (Test-Path (Join-Path $PkiDir 'private\easyrsa-tls.key'))) {
    Write-Info 'Generating a tls-crypt control-channel key using the Windows cryptographic RNG...'
    New-TlsCryptKey -Path (Join-Path $PkiDir 'private\easyrsa-tls.key')
}

$serverCert = Join-Path $PkiDir 'issued\server.crt'
$serverKey = Join-Path $PkiDir 'private\server.key'
if (-not (Test-Path $serverCert)) {
    $serverRequest = Join-Path $PkiDir 'reqs\server.req'
    if ((Test-Path $serverKey) -and (Test-Path $serverRequest)) {
        # Recover a previous build-server-full run which created the key/request
        # but failed while signing the request with the encrypted CA key.
        Write-Info 'Found the existing server key/request from an incomplete run; signing that request now...'
        Invoke-EasyRSA @('--batch', 'sign-req', 'server', 'server')
    }
    elseif (-not (Test-Path $serverKey) -and -not (Test-Path $serverRequest)) {
        Write-Info 'Creating the VPN server certificate and unencrypted service key...'
        Invoke-EasyRSA @('--batch', 'build-server-full', 'server', 'nopass')
    }
    else {
        throw 'The server PKI is incomplete (only its key or request exists). Inspect the Easy-RSA pki folder before proceeding; nothing was overwritten.'
    }
}
if (-not (Test-Path $serverCert) -or -not (Test-Path $serverKey)) {
    throw 'The server certificate or private key is still missing after Easy-RSA ran.'
}
# Refresh the server's runtime bundle; the CA private key is deliberately never copied here.
Copy-Item $caCert (Join-Path $ServerDir 'ca.crt') -Force
Copy-Item $serverCert (Join-Path $ServerDir 'server.crt') -Force
Copy-Item $serverKey (Join-Path $ServerDir 'server.key') -Force
Copy-Item (Join-Path $PkiDir 'private\easyrsa-tls.key') (Join-Path $ServerDir 'tls-crypt.key') -Force

# Read network/port before creating the server config. Always rewrite the
# generated config so changes to subnet, mask or port are applied on reruns.
Read-VpnNetworkSettings
Update-ExistingClientAddresses

$serverConfigPath = Join-Path $ServerDir 'server.ovpn'
$serverConfig = @"
port $script:VpnPort
proto udp
dev tun
topology subnet
server $script:VpnNetwork $script:VpnMask nopool
client-config-dir ccd
ccd-exclusive
client-to-client
max-clients $script:VpnClientCapacity
keepalive 10 60
persist-tun
dh none
ca ca.crt
cert server.crt
key server.key
tls-crypt tls-crypt.key
remote-cert-tls client
tls-version-min 1.2
data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
status openvpn-status.log
verb 3
"@
[System.IO.File]::WriteAllText($serverConfigPath, $serverConfig, [System.Text.Encoding]::ASCII)
Write-Info "Updated server config: $serverConfigPath"

$endpoint = Read-ServerEndpoint
[System.IO.File]::WriteAllText($EndpointFile, $endpoint + [Environment]::NewLine, [System.Text.Encoding]::ASCII)

Write-Host ''
Write-Host "Server configuration '$ServerName' is ready." -ForegroundColor Green
Write-Host "Server bundle: $ServerDir"
Write-Host "PKI (keep private): $PkiDir"
Write-Host "Server tunnel address: $(Get-ServerVpnAddress)"
Write-Host "VPN network: $script:VpnNetwork/$script:VpnPrefix"
Write-Host "UDP port: $script:VpnPort"
Write-Host ''
Write-Host 'No client certificates or client profiles were generated.' -ForegroundColor Cyan
Write-Host 'Run New-OpenVPN-Client.ps1 to select this server and issue a client package.' -ForegroundColor Cyan
Write-Warn ('Forward UDP ' + $script:VpnPort + ' on your router to this server PC, and keep its LAN address stable.')
