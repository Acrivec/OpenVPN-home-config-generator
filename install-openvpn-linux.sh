#!/usr/bin/env bash
set -Eeuo pipefail

# Usage: sudo ./install-openvpn-linux.sh [/path/to/OpenVPN-VPN/server]

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Run as root: sudo $0 [/path/to/server-bundle]" >&2
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="${1:-"$SCRIPT_DIR/OpenVPN-VPN/server"}"
if [[ ! -f "$SOURCE_DIR/server.ovpn" ]]; then
  SOURCE_DIR="$SCRIPT_DIR/server"
fi
if [[ ! -f "$SOURCE_DIR/server.ovpn" ]]; then
  echo "Cannot find server.ovpn in: $SOURCE_DIR" >&2
  echo "Pass the path to the generated OpenVPN-VPN/server directory as the first argument." >&2
  exit 1
fi
for f in ca.crt server.crt server.key tls-crypt.key; do
  [[ -f "$SOURCE_DIR/$f" ]] || { echo "Missing $SOURCE_DIR/$f" >&2; exit 1; }
done
[[ -d "$SOURCE_DIR/ccd" ]] || { echo "Missing client-config-dir: $SOURCE_DIR/ccd" >&2; exit 1; }

if ! command -v systemctl >/dev/null 2>&1; then
  echo 'This installer requires a systemd-based Linux distribution.' >&2
  exit 1
fi

if ! command -v openvpn >/dev/null 2>&1; then
  echo 'Installing OpenVPN from the distribution package repository...'
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y openvpn
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y openvpn
  elif command -v yum >/dev/null 2>&1; then
    yum install -y openvpn
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm openvpn
  elif command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive install openvpn
  else
    echo 'Unsupported package manager. Install OpenVPN 2.5+ and rerun this script.' >&2
    exit 1
  fi
fi

if ! command -v openvpn >/dev/null 2>&1; then
  echo 'OpenVPN installation did not produce an openvpn executable.' >&2
  exit 1
fi

VERSION="$(openvpn --version | awk 'NR==1 {print $2}')"
MAJOR="${VERSION%%.*}"
REST="${VERSION#*.}"
MINOR="${REST%%.*}"
if [[ ! "$MAJOR" =~ ^[0-9]+$ || ! "$MINOR" =~ ^[0-9]+$ ]] || (( MAJOR < 2 || (MAJOR == 2 && MINOR < 5) )); then
  echo "OpenVPN $VERSION is too old for this config. Install OpenVPN 2.5 or newer." >&2
  exit 1
fi

echo "Using OpenVPN $VERSION"
if systemctl cat openvpn-server@.service >/dev/null 2>&1; then
  CONFIG_DIR='/etc/openvpn/server'
  UNIT='openvpn-server@server'
elif systemctl cat openvpn@.service >/dev/null 2>&1; then
  # Compatibility with older systemd package layouts.
  CONFIG_DIR='/etc/openvpn'
  UNIT='openvpn@server'
else
  echo 'Could not find openvpn-server@.service or openvpn@.service after package installation.' >&2
  exit 1
fi

install -d -m 0755 "$CONFIG_DIR" "$CONFIG_DIR/ccd"
install -m 0644 "$SOURCE_DIR/ca.crt" "$CONFIG_DIR/ca.crt"
install -m 0644 "$SOURCE_DIR/server.crt" "$CONFIG_DIR/server.crt"
install -m 0600 "$SOURCE_DIR/server.key" "$CONFIG_DIR/server.key"
install -m 0600 "$SOURCE_DIR/tls-crypt.key" "$CONFIG_DIR/tls-crypt.key"
if [[ -f "$SOURCE_DIR/crl.pem" ]]; then
  install -m 0644 "$SOURCE_DIR/crl.pem" "$CONFIG_DIR/crl.pem"
fi

# Preserve existing CCD entries and add/refresh the generated ones.
cp -a "$SOURCE_DIR/ccd/." "$CONFIG_DIR/ccd/"
find "$CONFIG_DIR/ccd" -type f -exec chmod 0644 {} \;
chmod 0755 "$CONFIG_DIR/ccd"

CONFIG_FILE="$CONFIG_DIR/server.conf"
if [[ -f "$CONFIG_FILE" ]]; then
  cp -a "$CONFIG_FILE" "$CONFIG_FILE.bak.$(date +%Y%m%d-%H%M%S)"
fi
# The generated config uses paths relative to its own directory.
{
  printf 'cd %s\n' "$CONFIG_DIR"
  sed 's/\r$//' "$SOURCE_DIR/server.ovpn" | sed '/^[[:space:]]*cd[[:space:]]/d'
} > "$CONFIG_FILE"
chmod 0644 "$CONFIG_FILE"

# DCO was introduced in OpenVPN 2.6. On 2.5, it does not exist and client-to-client
# already uses the normal userspace routing path, so drop the 2.6-only directive.
if (( MAJOR == 2 && MINOR < 6 )); then
  sed -i '/^[[:space:]]*disable-dco[[:space:]]*$/d' "$CONFIG_FILE"
fi

systemctl daemon-reload
systemctl enable "$UNIT"
systemctl restart "$UNIT" 2>/dev/null || systemctl start "$UNIT"

# Open the listener in common host firewalls when one is active.
SERVER_PORT="$(awk '$1=="port" {print $2; exit}' "$CONFIG_FILE")"
SERVER_PORT="${SERVER_PORT:-12321}"
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
  ufw allow "$SERVER_PORT/udp"
elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-port="${SERVER_PORT}/udp"
  firewall-cmd --reload
else
  echo "No active UFW/firewalld rule manager detected; allow inbound UDP $SERVER_PORT in your firewall if applicable."
fi

if systemctl is-active --quiet "$UNIT"; then
  echo
  echo "OpenVPN server is active: $UNIT"
  echo "Config: $CONFIG_FILE"
  echo 'System startup: enabled.'
  echo "Router step still required: forward UDP $SERVER_PORT to this Linux host and keep its LAN address stable."
  echo 'The CA private key is not part of the server bundle and is not installed here.'
else
  echo "OpenVPN failed to start. Recent logs:" >&2
  journalctl -u "$UNIT" -n 60 --no-pager >&2 || true
  exit 1
fi
