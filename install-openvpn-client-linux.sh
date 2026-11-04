#!/usr/bin/env bash
set -Eeuo pipefail

# Usage: sudo ./install-openvpn-client-linux.sh [path/to/device.ovpn]

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Run as root: sudo $0 [path/to/device.ovpn]" >&2
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROFILE="${1:-}"
if [[ -z "$PROFILE" ]]; then
  shopt -s nullglob
  profiles=("$SCRIPT_DIR"/*.ovpn)
  if (( ${#profiles[@]} != 1 )); then
    echo "Expected exactly one .ovpn profile beside this script; found ${#profiles[@]}." >&2
    echo "Pass the profile path explicitly: sudo $0 ./device.ovpn" >&2
    exit 1
  fi
  PROFILE="${profiles[0]}"
fi
[[ -f "$PROFILE" ]] || { echo "Client profile not found: $PROFILE" >&2; exit 1; }
PROFILE="$(readlink -f -- "$PROFILE")"
for marker in '^client[[:space:]]*$' '^remote[[:space:]]+' '^<ca>[[:space:]]*$' '^<cert>[[:space:]]*$' '^<key>[[:space:]]*$' '^<tls-crypt>[[:space:]]*$'; do
  if ! grep -Eiq "$marker" "$PROFILE"; then
    echo "The selected file is not a complete self-contained client profile (missing marker: $marker)." >&2
    exit 1
  fi
done

if ! command -v systemctl >/dev/null 2>&1; then
  echo 'This installer requires a systemd-based Linux distribution.' >&2
  exit 1
fi

if ! command -v openvpn >/dev/null 2>&1; then
  echo 'OpenVPN is not installed. Installing it from the distribution package repository...'
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

command -v openvpn >/dev/null 2>&1 || { echo 'OpenVPN installation did not produce an openvpn executable.' >&2; exit 1; }
VERSION="$(openvpn --version | awk 'NR==1 {print $2}')"
if [[ ! "$VERSION" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+) ]]; then
  echo "Could not parse installed OpenVPN version: $VERSION" >&2
  exit 1
fi
MAJOR="${BASH_REMATCH[1]}"
MINOR="${BASH_REMATCH[2]}"
if (( MAJOR < 2 || (MAJOR == 2 && MINOR < 5) )); then
  echo "OpenVPN $VERSION is too old. This profile requires OpenVPN 2.5 or newer." >&2
  exit 1
fi
echo "Using OpenVPN $VERSION"

PROFILE_BASE="$(basename -- "$PROFILE")"
PROFILE_NAME="${PROFILE_BASE%.*}"
PROFILE_NAME="$(printf '%s' "$PROFILE_NAME" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9_-]+/-/g; s/^-+//; s/-+$//')"
[[ -n "$PROFILE_NAME" ]] || PROFILE_NAME='device'
PROFILE_NAME="${PROFILE_NAME:0:40}"
UNIT_NAME="homevpn-${PROFILE_NAME}"

if systemctl cat openvpn-client@.service >/dev/null 2>&1; then
  CONFIG_DIR='/etc/openvpn/client'
  UNIT="openvpn-client@${UNIT_NAME}"
elif systemctl cat openvpn@.service >/dev/null 2>&1; then
  # Compatibility with packages exposing only the older generic unit template.
  CONFIG_DIR='/etc/openvpn'
  UNIT="openvpn@${UNIT_NAME}"
else
  echo 'Could not find openvpn-client@.service or the legacy openvpn@.service unit template.' >&2
  echo 'Inspect the OpenVPN package/systemd unit files for this distribution.' >&2
  exit 1
fi

install -d -m 0755 "$CONFIG_DIR"
CONFIG_FILE="$CONFIG_DIR/${UNIT_NAME}.conf"
if [[ -e "$CONFIG_FILE" ]]; then
  cp -a -- "$CONFIG_FILE" "$CONFIG_FILE.bak.$(date +%Y%m%d-%H%M%S)"
  echo "Existing client config backed up."
fi
install -m 0600 -- "$PROFILE" "$CONFIG_FILE"

systemctl daemon-reload
systemctl enable "$UNIT"
# Do not block the installer on the remote VPN handshake. The OpenVPN client
# service should remain enabled and keep retrying if the server is offline.
systemctl --no-block restart "$UNIT" 2>/dev/null || systemctl --no-block start "$UNIT"
sleep 2
ACTIVE_STATE="$(systemctl show "$UNIT" --property=ActiveState 2>/dev/null | sed -n 's/^ActiveState=//p' | head -n 1)"

if [[ "$ACTIVE_STATE" == 'active' || "$ACTIVE_STATE" == 'activating' ]]; then
  echo
  echo "OpenVPN client service is active: ${UNIT}.service"
  echo "Config: $CONFIG_FILE"
  echo 'System startup: enabled.'
  echo 'The client service has been queued; it may remain activating until the first VPN connection succeeds.'
  echo 'OpenVPN will retry according to its profile if the server is temporarily unavailable.'
  echo
  echo 'Check connection/log status with:'
  echo "  sudo systemctl status ${UNIT}.service"
  echo "  sudo journalctl -u ${UNIT}.service -n 60 --no-pager"
  echo
  echo 'The .ovpn profile contains the device private key. Keep this file private and do not reuse it on another device.'
else
  echo "OpenVPN client failed to start: ${UNIT}.service" >&2
  journalctl -u "$UNIT" -n 60 --no-pager >&2 || true
  exit 1
fi
