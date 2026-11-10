#!/usr/bin/env bash
# Shared helpers for the phone-network scripts in ../bin.
#
# Source it from a script:
#   . "$(dirname -- "$0")/../lib/phone-net.sh"
#
# Every value can be overridden from the environment, which keeps the scripts
# usable if the phone, the SSID or the AP subnet ever change.

PHONE_SERIAL=${PHONE_SERIAL:-XPLO2EEA0001541}
PHONE_HOTSPOT_IP=${PHONE_HOTSPOT_IP:-10.244.108.165}
PHONE_AP_IP=${PHONE_AP_IP:-192.168.77.232}
PHONE_AP_CON=${PHONE_AP_CON:-phonelink}
PHONE_AP_SSID=${PHONE_AP_SSID:-PhoneLink}
PHONE_AP_IF=${PHONE_AP_IF:-wlp110s0}
PHONE_AP_ADDRESS=${PHONE_AP_ADDRESS:-192.168.77.1/24}
# Set by phoneLink.ap when the module owns the profile.
PHONE_AP_DECLARATIVE=${PHONE_AP_DECLARATIVE:-/etc/phone-link/ap-profile}
PHONE_AP_ENSURE_UNIT=${PHONE_AP_ENSURE_UNIT:-NetworkManager-ensure-profiles.service}
PHONE_NM_SYSTEM_CONNECTIONS=${PHONE_NM_SYSTEM_CONNECTIONS:-/etc/NetworkManager/system-connections}
PHONE_NM_RUN_CONNECTIONS=${PHONE_NM_RUN_CONNECTIONS:-/run/NetworkManager/system-connections}
PHONE_HOTSPOT_CON=${PHONE_HOTSPOT_CON:-XPLORE 2}
PHONE_HOTSPOT_SSID=${PHONE_HOTSPOT_SSID:-$PHONE_HOTSPOT_CON}
PHONE_AP_SUBNET=${PHONE_AP_SUBNET:-192.168.77.0/24}
PHONE_PROXY_PORT=${PHONE_PROXY_PORT:-1080}
PHONE_PROXY_USER=${PHONE_PROXY_USER:-proxy}
PHONE_PROXY_PKG=${PHONE_PROXY_PKG:-com.tokyoxpa3.androidproxy}
PHONE_ADB_PORT=${PHONE_ADB_PORT:-5555}
PHONE_SECRETS=${PHONE_SECRETS:-/etc/nixos/phone-socks-secrets}
# The ambulance box: a root-owned cache of the proxy APK, kept so the proxy
# can be reinstalled when the network it provides is the thing that broke.
PHONE_APK_CACHE=${PHONE_APK_CACHE:-/var/cache/phone-link}

log() { printf '%s\n' "$*" >&2; }
die() { log "error: $*"; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
as_root() {
  [ "$(id -u)" -eq 0 ] || exec sudo -- "$0" "$@"
}

# tcp_open IP [SECONDS] [PORT] -> true while something accepts the connection
tcp_open() {
  timeout "${2:-3}" bash -c "exec 3<>/dev/tcp/$1/${3:-$PHONE_PROXY_PORT}" 2>/dev/null
}

# phone_ap_pass -> the PhoneLink password, from the environment or secrets
phone_ap_pass() {
  if [ -n "${PHONE_AP_PASS:-}" ]; then
    printf '%s' "$PHONE_AP_PASS"
    return 0
  fi
  [ -r "$PHONE_SECRETS" ] \
    || die "cannot read $PHONE_SECRETS (run with sudo) or set PHONE_AP_PASS"
  # shellcheck disable=SC1090
  . "$PHONE_SECRETS"
  printf '%s' "${PHONE_AP_PASS:?PHONE_AP_PASS missing in $PHONE_SECRETS}"
}

# ap_declarative -> true when phoneLink.ap declares the AP profile
ap_declarative() {
  local name
  [ -r "$PHONE_AP_DECLARATIVE" ] || return 1
  IFS= read -r name <"$PHONE_AP_DECLARATIVE" || true
  [ "$name" = "$PHONE_AP_CON" ]
}

# phone_proxy_pass -> the proxy password, read from the root-only secrets file
phone_proxy_pass() {
  [ -r "$PHONE_SECRETS" ] || die "cannot read $PHONE_SECRETS (run with sudo)"
  # shellcheck disable=SC1090
  . "$PHONE_SECRETS"
  printf '%s' "${PHONE_SOCKS_PASS:?PHONE_SOCKS_PASS missing in $PHONE_SECRETS}"
}

# phone_proxy_check IP -> true if https://example.com loads through the proxy
phone_proxy_check() {
  local ip=$1 pass code
  pass=$(phone_proxy_pass) || return 1
  tcp_open "$ip" 3 "$PHONE_PROXY_PORT" || { log "$ip:$PHONE_PROXY_PORT closed"; return 1; }
  code=$(curl -4 -s -m 20 \
           --socks5-hostname "$PHONE_PROXY_USER:$pass@$ip:$PHONE_PROXY_PORT" \
           -o /dev/null -w '%{http_code}' https://example.com)
  log "$ip:$PHONE_PROXY_PORT -> https://example.com = ${code:-000}"
  [ "$code" = 200 ]
}

# phone_apk_cached -> newest proxy APK in the ambulance box or a user cache
phone_apk_cached() {
  local dir f newest=""
  for dir in "$PHONE_APK_CACHE" "${PHONE_APK_DIR:-}" \
    "${XDG_CACHE_HOME:-$HOME/.cache}/phone-link"; do
    [ -n "$dir" ] && [ -d "$dir" ] || continue
    for f in "$dir"/*.apk; do
      [ -f "$f" ] || continue
      if [ -z "$newest" ] || [ "$f" -nt "$newest" ]; then newest=$f; fi
    done
  done
  [ -n "$newest" ] || return 1
  printf '%s\n' "$newest"
}

# adb_transport -> the serial of a network (non-USB) adb transport
adb_transport() {
  adb devices 2>/dev/null \
    | awk '$2 == "device" && $1 ~ /:/ {print $1; found = 1} END {exit found ? 0 : 1}'
}

# phone_serial -> serial of any attached device (USB or network)
phone_serial() {
  local serial
  # Capture first: piping into head would mask awk's failure status and leave
  # callers with an empty serial instead of "no phone attached".
  serial=$(adb devices 2>/dev/null | awk '$2 == "device" {print $1; exit}')
  [ -n "$serial" ] || return 1
  printf '%s\n' "$serial"
}

# phone_ips -> every non-loopback IPv4 address the phone currently owns
phone_ips() {
  local s
  s=$(phone_serial) || return 1
  adb -s "$s" shell 'ip -4 -o addr show 2>/dev/null' 2>/dev/null \
    | tr -d '\r' | awk '{print $4}' | cut -d/ -f1 | grep -v '^127\.'
}
