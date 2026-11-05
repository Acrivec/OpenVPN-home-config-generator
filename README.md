# OpenVPN Home Server Kit

PowerShell tools for creating independent OpenVPN servers, issuing per-device certificates and VPN addresses, and packaging each client for Windows or Linux. Each server has its own CA, subnet and endpoint; the CA private key stays on the Windows generator machine.

## Network model

- All profiles use **`dev tun` (Layer 3/IP)**. This is a routed VPN, not an Ethernet bridge. TUN describes OpenVPN's packet mode, not a Windows adapter package.
- Windows OpenVPN Community **2.7.0+** uses **ovpn-dco** by default, including server mode. OpenVPN creates the DCO adapter on demand and falls back to **tap-windows6** when necessary. The kit does not pin an adapter with `dev-node`. A TAP fallback still operates in TUN mode. Wintun support was removed in OpenVPN 2.7.
- Linux uses DCO when a compatible kernel driver is available; otherwise it uses the normal TUN driver.
- VPN clients can communicate with each other. With DCO, the operating system routes peer traffic, so the server installer enables IP forwarding (and on Windows sets Routing and Remote Access to Automatic). Reboot Windows if the installer reports that routing settings changed.
- The kit does not bridge the VPN to the physical LAN, push a route to the home LAN, configure NAT, or push `redirect-gateway`. Clients receive no home-LAN or general-Internet route. Actual reachability to other networks still depends on the server's routes and firewall.

The default VPN network is `192.168.4.0/24`. Choose a different, non-overlapping subnet if needed.

## Requirements

- **Generator:** Windows 10/11, Windows PowerShell 5.1. First server creation downloads Easy-RSA 3.2.7 and verifies its SHA-256.
- **Windows server:** OpenVPN Community **2.7.0+**, `OpenVPNService`, and the default network-driver components. **2.7.8-I002** is the current recommended MSI. The server installer configures an existing installation; it does not install or upgrade OpenVPN.
- **Windows client:** Windows 10/11 and OpenVPN Community **2.5.0+** with `OpenVPNService`. OpenVPN 2.5 is unsupported upstream; prefer 2.6.23+ or 2.7.8. If OpenVPN is absent, the client installer downloads and verifies **2.7.8-I002**.
- **Linux server/client:** systemd and OpenVPN **2.5.0+** for configuration compatibility. OpenVPN 2.5 is unsupported upstream; prefer a supported 2.6.x or 2.7.x release. Linux installers can install OpenVPN using `apt`, `dnf`, `yum`, `pacman` or `zypper`.

Generate server and client credentials on Windows. For a Linux server, transfer only the generated `server` runtime directory, not the `pki` directory.

## Usage

<details>
<summary><strong>Windows — Server</strong></summary>

1. Run `New-OpenVPN-Server.ps1` from the extracted kit directory.
2. Enter a server name, VPN subnet, UDP port and public IP/DDNS endpoint. Defaults: `192.168.4.0/24`, UDP `12321`.
3. Protect and back up `OpenVPN-VPN\servers\<name>\pki` and the CA passphrase. They are needed to issue or revoke certificates.
4. Install OpenVPN Community 2.7.0+ with its default network-driver components.
5. Run **PowerShell as Administrator** and execute `Install-OpenVPN-Server-Windows.ps1`. Select the server if prompted. It removes legacy `dev-node`/`disable-dco` entries, configures `OpenVPNService`, adds the UDP firewall rule and detects the tunnel interface without relying on its alias. Reboot if it reports that Windows routing settings changed.
6. Forward the selected UDP port on your router to the server PC's stable LAN address.

</details>

<details>
<summary><strong>Linux — Server</strong></summary>

Copy `OpenVPN-VPN/servers/<name>/server/` and `install-openvpn-server-linux.sh` to the Linux host, keeping them together. Then run:

```bash
sudo bash ./install-openvpn-server-linux.sh ./server
```

The installer deploys the config and credentials, enables IPv4 forwarding for client-to-client routing, enables/starts the systemd service, and opens the UDP port in UFW/firewalld when active. Forward that UDP port on your router to the Linux host's stable LAN address.

Do not copy the CA private key or the `pki` directory to the server.

</details>

<details>
<summary><strong>Windows — Client</strong></summary>

1. On the Windows generator, run `New-OpenVPN-Client.ps1` and select a server.
2. Enter a unique device name. The generator issues its certificate, reserves a VPN address and creates `OpenVPN-VPN\servers\<name>\client-packages\<device>.zip`.
3. Deploy the updated server bundle first, rerunning the server installer so its new CCD assignment is available.
4. Copy only that device ZIP to the Windows client, extract it, run `Install-Windows.cmd` and approve UAC.

The installer installs OpenVPN if missing, imports the profile into the automatic service config directory, enables `OpenVPNService` at startup, and detects DCO/TAP-Windows interfaces to set their network category to **Private**. It does not change Wi-Fi or Ethernet profiles.

</details>

<details>
<summary><strong>Linux — Client</strong></summary>

Generate the device ZIP on Windows and deploy the updated server bundle first. Copy only the ZIP to the Linux client, extract it, then run:

```bash
sudo bash ./install-openvpn-client-linux.sh
```

The installer installs OpenVPN if needed and enables a systemd client service at startup. Inspect it with `systemctl status` and `journalctl -u <service-name>`.

</details>

## Client maintenance

Refresh a package after changing the server endpoint/port without replacing the certificate or VPN address:

```powershell
.\New-OpenVPN-Client.ps1 -ServerName home -CommonName laptop -RefreshExisting
```

Revoke a device:

```powershell
.\Revoke-OpenVPN-Client.ps1 -ServerName home -CommonName laptop
```

Deploy the updated server bundle after revocation so the new CRL becomes active. Revoked device names and addresses remain reserved.

## Security

- A client ZIP contains that device's private key and a shared TLS control-channel key. Treat it as a secret and create a separate ZIP for every device.
- Keep the CA private key, Easy-RSA PKI and CA passphrase on the generator machine; back them up securely.
- The server runtime bundle contains the server private key. Transfer it securely; never include the CA private key.
