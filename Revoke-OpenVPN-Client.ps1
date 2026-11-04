#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$CommonName
)

$ErrorActionPreference = 'Stop'
$Root = Join-Path $PSScriptRoot 'OpenVPN-VPN'
$EasyRSAInstall = Join-Path $Root 'easy-rsa'
$ServerDir = Join-Path $Root 'server'

if ([string]::IsNullOrWhiteSpace($CommonName)) {
    $CommonName = Read-Host 'Certificate/device name to revoke (example: phone)'
}
$CommonName = $CommonName.Trim().ToLowerInvariant()
if ($CommonName -notmatch '^[a-z0-9][a-z0-9_-]{0,31}$') {
    throw 'Invalid device name. Expected 1-32 lowercase letters, digits, underscores or hyphens.'
}

$startBat = Get-ChildItem -Path $EasyRSAInstall -Filter 'EasyRSA-Start.bat' -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $startBat) { throw "Easy-RSA was not found under $EasyRSAInstall. Run New-OpenVPN-VPN.ps1 first." }
$easyRSAHome = Split-Path -Parent $startBat.FullName
$pkiDir = Join-Path $easyRSAHome 'pki'
$certPath = Join-Path $pkiDir "issued\$CommonName.crt"
if (-not (Test-Path $certPath)) { throw "No issued certificate found for '$CommonName'." }

Write-Host ''
Write-Host "This will revoke the certificate for '$CommonName'." -ForegroundColor Yellow
Write-Host 'The device will be rejected only after the updated CRL is deployed to the running server.' -ForegroundColor Yellow
$answer = Read-Host 'Type REVOKE to continue'
if ($answer -cne 'REVOKE') { Write-Host 'Cancelled.'; exit 0 }

$caKey = Join-Path $pkiDir 'private\ca.key'
if (-not (Test-Path $caKey)) { throw "CA private key not found: $caKey" }

function ConvertFrom-SecureStringToPlainText([Security.SecureString]$SecureValue) {
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureValue)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
}

$caPassphrase = $null
for ($attempt = 1; $attempt -le 3; $attempt++) {
    $secureValue = Read-Host 'Enter the CA passphrase (input is hidden)' -AsSecureString
    $plainValue = ConvertFrom-SecureStringToPlainText $secureValue
    if ([string]::IsNullOrEmpty($plainValue) -or $plainValue -match '[^\x20-\x7E]') {
        Write-Warning 'Use a non-empty passphrase containing printable ASCII characters.'
        continue
    }
    $oldPass = $env:OPENVPN_CA_PASS
    $oldErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $env:OPENVPN_CA_PASS = $plainValue
        $null = & (Join-Path $easyRSAHome 'openssl.exe') pkey -in $caKey -passin 'env:OPENVPN_CA_PASS' -noout 2>$null
        $validationExit = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $oldErrorAction
        $env:OPENVPN_CA_PASS = $oldPass
    }
    if ($validationExit -eq 0) { $caPassphrase = $plainValue; break }
    Write-Warning 'That passphrase did not decrypt the CA key. Try again.'
}
if ($null -eq $caPassphrase) { throw 'Could not unlock the CA key after three attempts.' }

$shellExe = Join-Path $easyRSAHome 'bin\sh.exe'
$opensslExe = Join-Path $easyRSAHome 'openssl.exe'
if (-not (Test-Path $shellExe)) { throw "Easy-RSA POSIX shell is missing: $shellExe" }
if (-not (Test-Path $opensslExe)) { throw "Easy-RSA bundled OpenSSL is missing: $opensslExe" }

$oldEasyRsa = $env:EASYRSA
$oldEasyRsaPki = $env:EASYRSA_PKI
$oldEasyRsaOpenSsl = $env:EASYRSA_OPENSSL
$oldCrlDays = $env:EASYRSA_CRL_DAYS
$oldHome = $env:HOME
$oldEnv = $env:ENV
$oldPath = $env:PATH
$oldPassIn = $env:EASYRSA_PASSIN
$oldCaPass = $env:OPENVPN_CA_PASS
Push-Location $easyRSAHome
try {
    $homePosix = $easyRSAHome.Replace('\', '/')
    $env:EASYRSA = $homePosix
    $env:EASYRSA_PKI = $pkiDir.Replace('\', '/')
    $env:EASYRSA_OPENSSL = $opensslExe.Replace('\', '/')
    $env:HOME = $homePosix
    $env:ENV = '/disable-env'
    $env:PATH = "$easyRSAHome;$(Join-Path $easyRSAHome 'bin');$oldPath"
    $env:OPENVPN_CA_PASS = $caPassphrase
    $env:EASYRSA_PASSIN = 'env:OPENVPN_CA_PASS'

    function ConvertTo-PosixArgument([string]$Value) {
        return "'" + $Value.Replace("'", "'\''") + "'"
    }
    function Invoke-EasyRSARevoke([string[]]$ArgumentList) {
        $quoted = @('./easyrsa') + @($ArgumentList | ForEach-Object { ConvertTo-PosixArgument ([string]$_) })
        $command = $quoted -join ' '
        Write-Host ("[+] Easy-RSA: " + ($ArgumentList -join ' ')) -ForegroundColor Cyan
        & $shellExe '-c' $command
        $exitCode = $LASTEXITCODE
        if ($null -eq $exitCode -or $exitCode -ne 0) {
            throw "Easy-RSA failed with exit code $exitCode while running: $($ArgumentList -join ' ')"
        }
    }
    $env:EASYRSA_CRL_DAYS = '3650'
    Invoke-EasyRSARevoke @('--batch', 'revoke-issued', $CommonName)
    Invoke-EasyRSARevoke @('--batch', 'gen-crl')
}
finally {
    $env:EASYRSA = $oldEasyRsa
    $env:EASYRSA_PKI = $oldEasyRsaPki
    $env:EASYRSA_OPENSSL = $oldEasyRsaOpenSsl
    $env:EASYRSA_CRL_DAYS = $oldCrlDays
    $env:HOME = $oldHome
    $env:ENV = $oldEnv
    $env:PATH = $oldPath
    $env:EASYRSA_PASSIN = $oldPassIn
    $env:OPENVPN_CA_PASS = $oldCaPass
    Pop-Location
}

$crlPath = Join-Path $pkiDir 'crl.pem'
if (-not (Test-Path $crlPath)) { throw 'Easy-RSA reported success but pki\crl.pem was not created.' }
New-Item -ItemType Directory -Path $ServerDir -Force | Out-Null
Copy-Item $crlPath (Join-Path $ServerDir 'crl.pem') -Force

$serverConfigPath = Join-Path $ServerDir 'server.ovpn'
if (-not (Test-Path $serverConfigPath)) { throw "Server config not found: $serverConfigPath" }
$config = Get-Content -Path $serverConfigPath -Raw
if ($config -notmatch '(?m)^\s*crl-verify\s+') {
    $config = $config.TrimEnd() + "`r`ncrl-verify crl.pem`r`n"
    [System.IO.File]::WriteAllText($serverConfigPath, $config, [System.Text.Encoding]::ASCII)
}

Write-Host ''
Write-Host "Certificate '$CommonName' revoked and new CRL generated." -ForegroundColor Green
Write-Host "CRL: $(Join-Path $ServerDir 'crl.pem')"
Write-Host 'Deploy the updated server bundle and restart OpenVPN:'
Write-Host '  Windows: run Install-OpenVPN-Windows.ps1 as Administrator.'
Write-Host '  Linux: copy the updated server directory and rerun install-openvpn-linux.sh as root.'
Write-Host 'The CCD entry remains in place so its VPN IP and device name are not accidentally reused.'
