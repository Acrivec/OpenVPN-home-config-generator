# OpenVPN Home Server Kit

A small PowerShell/Bash toolkit to create an OpenVPN server, issue one certificate/profile per device, deploy the server on Windows or Linux, install clients, and revoke client certificates.

## How it works

1. Run the generator **on the server-side Windows machine**. It creates/reuses the CA and server identity, then creates one client certificate, static VPN address, and `.ovpn` profile per run.
2. Install the server with the Windows or Linux server installer.
3. Transfer only the generated `client-packages/<device>.zip` to that device. The ZIP contains that device's `.ovpn` profile, Windows/Linux client installers, and instructions. It contains no server bundle, server private key, CA private key, or Easy-RSA database.
4. Run the matching client installer on the device.

Default VPN network: `192.168.4.0/24` (server `192.168.4.1`, first client `192.168.4.2`). Default UDP port: `12321`.

## Requirements

- **Generator:** Windows PowerShell 5.1+, internet access on first run to download the official Easy-RSA 3.2.7 Windows bundle (SHA-256 is verified).
- **Windows server:** OpenVPN Community 2.6+ already installed, including `OpenVPNService` and the TAP-Windows driver. The server installer does not install or upgrade OpenVPN.
- **Linux server/client:** systemd-based Linux distribution and root/sudo access. Installers support `apt`, `dnf`, `yum`, `pacman`, and `zypper` package managers.
- **Windows client:** Windows 10/11, PowerShell 5.1+, and Administrator rights. If OpenVPN is missing, the client installer downloads the official OpenVPN Community 2.7.8-I002 MSI and verifies its release signature before installing. If OpenVPN is already present but its background service is missing, the script asks before modifying/upgrading it to add the service and drivers. GnuPG/Gpg4win may be needed if the MSI does not expose a valid Authenticode signature.

## Generate the server and first client

Run from the kit directory on the Windows machine that will hold the CA and server files:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\New-OpenVPN-VPN.ps1
```

On first run, choose a strong CA passphrase and keep it safe. The generator asks for the VPN network/prefix, UDP port, public IPv4 address or DDNS hostname, and device name. Defaults are saved for later runs. Each successful run adds one client.

## Install the server

### Windows server

Run from an elevated PowerShell window on the server:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\Install-OpenVPN-Server-Windows.ps1
```

Select the TAP-Windows adapter by its exact Windows network adapter name when prompted. The installer deploys the generated server files to OpenVPN's `config-auto` directory, configures the OpenVPN service, service ACLs and log/status paths, adds the inbound UDP firewall rule, and checks the daemon startup log. It uses the existing OpenVPN installation; it does not download, install, upgrade, or uninstall OpenVPN.

### Linux server

Copy the generated `OpenVPN-VPN/server` directory and `install-openvpn-server-linux.sh` to the Linux server. Then run:

```bash
sudo bash ./install-openvpn-server-linux.sh /path/to/server
```

The script installs OpenVPN from the distribution repository if needed, deploys the server files and CCD assignments, enables/starts the systemd server unit, and opens the UDP port in UFW or firewalld when one is active.

### Router

Forward the selected **UDP** port to the server's physical LAN IPv4 address. Reserve that address in DHCP or configure it statically. The VPN cannot accept remote connections until this is done.

## Install a client

After generation, the server creates:

```text
OpenVPN-VPN/
  clients/<device>.ovpn
  client-packages/
    <device>.zip
    <device>/
      <device>.ovpn
      Install-OpenVPN-Client-Windows.ps1
      install-openvpn-client-linux.sh
      README.txt
```

Transfer only the device's ZIP to the client machine. Extract it there.

**Windows client** — open PowerShell as Administrator in the extracted directory:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\Install-OpenVPN-Client-Windows.ps1
```

The script installs OpenVPN Community if missing, including its GUI, background service, and network drivers. It copies the profile into OpenVPN's `config-auto` directory, restricts access to the embedded private key, and configures `OpenVPNService` for automatic connection at system startup. If an existing installation lacks `OpenVPNService`, it asks before modifying/upgrading that installation. Existing installations with the service already present are left at their current version. To use another profile path, pass `-ProfilePath .\device.ovpn`.

**Linux client** — from the extracted directory:

```bash
sudo bash ./install-openvpn-client-linux.sh
```

The script installs OpenVPN from the distribution repository if needed, puts the profile in the appropriate systemd client configuration directory, and enables/starts the client service. To use another profile path, pass it as the first argument.

Connection status on Linux:

```bash
sudo systemctl status openvpn-client@homevpn-<device>.service
sudo journalctl -u openvpn-client@homevpn-<device>.service -n 60 --no-pager
```

The exact unit name is printed by the installer. On older distributions it may use `openvpn@homevpn-<device>` instead.

## Add devices or change settings

Run `New-OpenVPN-VPN.ps1` again on the server and enter a new device name. It reuses the existing CA, server identity, and TLS control-channel key, then creates the new certificate, CCD assignment, `.ovpn` profile, and client ZIPs. Existing client packages are rebuilt on each generator run, so endpoint changes are included in the refreshed ZIPs.

After adding a client, rerun the relevant **server installer** so the new CCD entry is deployed. The generator supports VPN prefixes `/16` through `/30`; the server uses network + 1 and clients use network + 2 onward. Avoid subnet overlap with the server LAN and networks commonly used by clients.

The configuration routes the VPN subnet only. It does **not** redirect all Internet traffic and does **not** automatically provide access to the server's physical home LAN. Client-to-client communication inside the VPN is enabled. The Windows server installer uses a TAP-Windows virtual Ethernet adapter; Windows clients use their installed OpenVPN client driver. This kit does not create a physical-LAN bridge.

## Revoke a client

Run on the server-side Windows machine:

```powershell
.\Revoke-OpenVPN-Client.ps1 -CommonName phone
```

Replace `phone` with the device's certificate name. The script asks for confirmation and the CA passphrase, revokes the certificate, generates a new CRL, and updates the server bundle. It also removes that device's generated `.ovpn` profile and client ZIP so they are not accidentally redistributed. Rerun the relevant server installer to deploy the updated CRL and restart OpenVPN. The CCD entry and PKI revocation record are retained so the VPN address is not accidentally reassigned.

## Files and security

| File | Purpose |
|---|---|
| `New-OpenVPN-VPN.ps1` | Creates/reuses the CA and server identity; generates client certificates, profiles, CCD entries, and per-device ZIP packages. |
| `Install-OpenVPN-Server-Windows.ps1` | Deploys the server on an existing Windows OpenVPN installation. |
| `install-openvpn-server-linux.sh` | Installs/deploys the server on a systemd-based Linux host. |
| `Install-OpenVPN-Client-Windows.ps1` | Installs/configures a Windows client from one `.ovpn` profile. |
| `install-openvpn-client-linux.sh` | Installs/configures a Linux client from one `.ovpn` profile. |
| `Revoke-OpenVPN-Client.ps1` | Revokes a client certificate and generates an updated CRL. |

- The encrypted CA private key is stored under `OpenVPN-VPN/easy-rsa/.../pki` and is not copied to the server runtime directory or client ZIPs.
- `server.key` and client private keys are unencrypted so their services can start without an interactive key-password prompt.
- Each `.ovpn` profile embeds the device private key and certificate, public CA certificate, and shared `tls-crypt` key. Treat the profile and its ZIP as secrets. Transfer them securely, do not reuse profiles between devices, and remove obsolete copies.
- Keep a secure backup of the entire Easy-RSA `pki` directory and the CA passphrase. Without them, issuing/revoking clients later may not be possible.
- Do not commit generated keys, profiles, client ZIPs, or the PKI directory to a public Git repository.
