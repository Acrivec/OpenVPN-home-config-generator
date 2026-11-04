# OpenVPN Home Server Kit

A small PowerShell/Bash toolkit for creating and deploying an OpenVPN server, issuing per-device client profiles, and revoking lost or retired clients.

## What it does

- Creates an IPv4 VPN using the **TAP-Windows virtual Ethernet adapter** on Windows and UDP (default port `12321`).
- Assigns the server the first usable address in the VPN subnet and gives each client a persistent address through CCD files.
- Enables client-to-client communication.
- Uses TAP (virtual Ethernet) on Windows; this kit does not configure a physical-LAN bridge.
- Creates a Certificate Authority (CA), server certificate, unique client certificates, and self-contained `.ovpn` profiles.
- Supports a Windows server or a systemd-based Linux server.
- Provides a separate client-certificate revocation script.

Default VPN network: `192.168.4.0/24` — server `192.168.4.1`, first client `192.168.4.2`.

## Requirements

### Generate certificates and profiles

- Windows PowerShell 5.1 or newer.
- Internet access on first run to download the official Easy-RSA 3.2.7 Windows bundle. The generator verifies its SHA-256 before extracting it.

### Windows server

- OpenVPN Community already installed, including `OpenVPNService` and the TAP-Windows driver.
- OpenVPN **2.6.0 or newer**.
- Run the Windows installer from an elevated PowerShell session.

The Windows installer configures an existing OpenVPN installation; it does **not** download, install, upgrade, or uninstall OpenVPN.

### Linux server

- A systemd-based Linux distribution.
- Root/sudo access. The Linux installer can install OpenVPN through `apt`, `dnf`, `yum`, `pacman`, or `zypper` if it is not already installed. It supports OpenVPN 2.5 or newer.

## Quick start — Windows

1. Open PowerShell in the kit directory and run:

   ```powershell
   Set-ExecutionPolicy -Scope Process Bypass -Force
   .\New-OpenVPN-VPN.ps1
   ```

2. On first run, choose a strong CA passphrase and keep it safe. The generator then asks for the VPN network/prefix, UDP port, public IPv4 address or DDNS hostname, and a device name. Defaults are saved and offered on later runs.

3. Run the Windows installer as Administrator:

   ```powershell
   .\Install-OpenVPN-Windows.ps1
   ```

4. Select the TAP-Windows adapter by its exact Windows network adapter name when prompted. The selected name is saved for later installer runs.

5. Configure your router to forward the chosen **UDP** port to the server PC's physical LAN IPv4 address. Give that LAN address a DHCP reservation or static assignment.

6. Import the matching file from `OpenVPN-VPN\clients\` into the OpenVPN app on each device. Each device must use its own profile.

The Windows installer deploys the server bundle to `C:\Program Files\OpenVPN\config-auto`, configures the OpenVPN system service to start automatically, adds a Windows Firewall inbound rule for the selected UDP port, and checks the daemon log for `Initialization Sequence Completed`. It also sets the selected TAP adapter's Windows network category to **Private** after successful initialization. It does not change the physical Ethernet/Wi-Fi adapter.

For OpenVPN 2.7, the installer reads the log directory from `HKLM\SOFTWARE\OpenVPN\log_dir` (commonly `C:\ProgramData\OpenVPN\Log`). It explicitly grants `NT SERVICE\OpenVPNService` the required runtime read/traverse permissions, grants log-directory write access, and puts the status file in that writable log directory. Server private keys remain readable by the service but restricted from ordinary users. The installed Windows config uses absolute credential paths and the selected TAP adapter; the generated `server.ovpn` remains portable for Linux deployment.

## Linux deployment

Copy the generated `OpenVPN-VPN/server` directory and `install-openvpn-linux.sh` to the Linux host. From the kit directory, run:

```bash
sudo ./install-openvpn-linux.sh /path/to/OpenVPN-VPN/server
```

The script installs OpenVPN if needed, deploys the server config/certificates/keys/CCD files, enables and starts the appropriate systemd unit, and opens the UDP port in UFW or firewalld when one is active. Router port forwarding to the Linux host is still required.

## Add devices and change settings

Run `New-OpenVPN-VPN.ps1` again to add another device. It reuses the existing CA, server identity, and TLS control-channel key, then creates a new client certificate, CCD assignment, and self-contained `.ovpn` profile. **Each successful run creates one additional client profile.** After adding a device, rerun the relevant server installer so the new CCD entry is deployed.

The generator supports VPN prefixes `/16` through `/30` and displays the address/client capacity for each. The network address must be the actual network boundary for the selected prefix. The server uses network + 1; clients use network + 2 onward. Changing the VPN subnet updates existing CCD assignments while preserving addresses where possible; it does not require new client certificates or profiles. Restart/redeploy the server after changing settings.

Choose a VPN subnet that does not overlap the server's LAN or networks commonly used by client devices. The configuration routes the VPN subnet only: it does **not** redirect all Internet traffic and does **not** automatically provide access to the server's physical home LAN. Client-to-client communication inside the VPN is enabled.

## Revoke a client

Run from PowerShell in the kit directory:

```powershell
.\Revoke-OpenVPN-Client.ps1 -CommonName phone
```

Replace `phone` with the device name used when its certificate was created. The script asks for explicit confirmation and the CA passphrase, revokes the certificate, generates a new CRL, and updates the source server bundle. Deploy the updated bundle and restart OpenVPN by rerunning the Windows or Linux installer. The CCD entry is retained so its VPN address is not accidentally reassigned.

## Generated files and security

The generator creates:

```text
OpenVPN-VPN/
  server/       Server config, certificates/keys, CCD entries, optional CRL
  clients/      One self-contained .ovpn profile per device
  easy-rsa/     Easy-RSA program files and the CA/PKI database
  server-settings.json
  server-endpoint.txt
```

- The CA private key (`easy-rsa/.../pki/private/ca.key`) is encrypted with the CA passphrase. It is used to issue and revoke certificates and is **not** copied to the server runtime directory.
- `server.key` and client private keys are unencrypted so the server and clients can start without an interactive key-password prompt.
- Each `.ovpn` profile embeds that device's private key and certificate, the public CA certificate, and the shared `tls-crypt` key. Treat the whole profile as a secret and transfer it securely. Do not reuse one device's profile on another device.
- Keep a secure backup of the **entire Easy-RSA `pki` directory** and the CA passphrase. Without the CA key/database, issuing or revoking clients later may not be possible.
- Keep secure backups of the server bundle and each client profile. Do not commit generated keys, profiles, or the PKI directory to a public Git repository.

## Kit files

| File | Purpose |
|---|---|
| `New-OpenVPN-VPN.ps1` | Creates/reuses the CA and server identity; generates a client certificate, static address assignment, and `.ovpn` profile. |
| `Install-OpenVPN-Windows.ps1` | Deploys the server to an existing Windows OpenVPN installation and configures its service, TAP adapter, ACLs, log/status paths, and firewall rule. |
| `install-openvpn-linux.sh` | Installs/deploys the server on a systemd-based Linux host. |
| `Revoke-OpenVPN-Client.ps1` | Revokes a client certificate and generates the updated CRL. |
