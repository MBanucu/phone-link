#!/usr/bin/env bash
# Hermetic tests for bin/phone-net-status: the tether interface is derived from
# the route to the phone's rndis0 address, not hard-coded. Stub adb/ip/nmcli and
# curl; no phone, no network, no root.
set -u

BASH_BIN=$(command -v bash)
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/bin/phone-net-status
. "$ROOT/tests/lib/harness.sh"
suite


stub adb
answer adb <<'EOF'
args=("$@")
if [ "${args[0]:-}" = "-s" ]; then args=("${args[@]:2}"); fi
case "${args[0]:-}" in
  devices) cat "$LOG/devices" ;;
  shell)
    cmd="${args[*]:1}"
    case "$cmd" in
      *"ip -4 addr show rndis0"*) cat "$LOG/rndis" ;;
      *"ip -4 -o addr show"*) cat "$LOG/ips" ;;
      *"cmd wifi status"*) printf 'Wifi is connected to "PhoneLink"\n' ;;
      *"settings get global"*) printf '1\n5555\n' ;;
    esac
    ;;
esac
EOF

stub ip
answer ip <<'EOF'
printf '%s\n' "$*" >>"$LOG/ip_calls"
case "$*" in
  "route get "*) [ -f "$LOG/route_get" ] && cat "$LOG/route_get" ;;
  "route show default") cat "$LOG/default_route" ;;
  "rule show") cat "$LOG/rules" ;;
  "-4 -br addr show "*)
    iface=${5}
    [ -f "$LOG/addr_$iface" ] && cat "$LOG/addr_$iface"
    ;;
esac
EOF

stub nmcli
answer nmcli <<'EOF'
case "$*" in
  "-t -f NAME,DEVICE con show --active") printf 'phonelink:wlp110s0\n' ;;
  "-t -f NAME,TYPE con show") printf 'phonelink:wifi\n' ;;
esac
EOF

stub systemctl
answer systemctl <<'EOF'
printf 'inactive\n'
EOF

# Both proxy probes are closed: this suite is about the tether address.
stub timeout
answer timeout <<'EOF'
exit 1
EOF

stub curl
answer curl <<'EOF'
printf '%s' "$(cat "$LOG/code" 2>/dev/null || echo 000)"
EOF

# No mDNS lookup: the phone is a stub and this suite is not about adb discovery.
export PHONE_ADB_MDNS=0

set_state() {
  printf 'List of devices attached\nXPLO2EEA0001541\tdevice\n' >"$LOG/devices"
  printf '53: rndis0    inet 10.9.9.9/24 brd 10.9.9.255 scope global rndis0\n' >"$LOG/rndis"
  printf '2: wlan0    inet 192.168.77.232/24 brd 192.168.77.255 scope global wlan0\n' >"$LOG/ips"
  printf '10.9.9.9 dev enp55s0u2 src 10.9.9.10 uid 1000\n' >"$LOG/route_get"
  printf 'enp55s0u2 UP 10.9.9.10/24\n' >"$LOG/addr_enp55s0u2"
  printf 'enp55s0u1 UP 10.0.0.1/24\n' >"$LOG/addr_enp55s0u1"
  printf 'enp9s0 UP 10.42.0.1/24\n' >"$LOG/addr_enp9s0"
  printf 'wlp110s0 UP 192.168.77.1/24\n' >"$LOG/addr_wlp110s0"
  printf 'default via 192.168.77.232 dev wlp110s0\n' >"$LOG/default_route"
  printf '2022: from all fwmark 0x7e6 lookup 2022\n' >"$LOG/rules"
  printf '200' >"$LOG/code"
  rm -f "$LOG/ip_calls"
}

run() {
  "$BASH_BIN" "$SCRIPT" "$@" >"$LOG/out" 2>&1
}

# 1. The live host names enp55s0u2: the address comes from that interface.
set_state
if run; then ok "status exits 0"; else bad "status exits 0" "$(cat "$LOG/out")"; fi
grep '^tether address' "$LOG/out" | grep -q '10.9.9.10/24' \
  && ok "shows the tether interface address" \
  || bad "shows the tether interface address" "$(cat "$LOG/out")"
grep -qx 'route get 10.9.9.9' "$LOG/ip_calls" && ok "asks the route to rndis0" \
  || bad "asks the route to rndis0" "$(cat "$LOG/ip_calls")"
grep -qx -- '-4 -br addr show enp55s0u2' "$LOG/ip_calls" \
  && ok "reads the interface the route names" \
  || bad "reads the interface the route names" "$(cat "$LOG/ip_calls")"
grep -qx -- '-4 -br addr show enp55s0u1' "$LOG/ip_calls" \
  && bad "does not use the old hard-coded name" || ok "does not use the old hard-coded name"

# 2. PHONE_TETHER_IF wins: no route lookup, that interface is read.
set_state
PHONE_TETHER_IF=enp9s0 run
grep -qx 'route get 10.9.9.9' "$LOG/ip_calls" \
  && bad "the override skips the route" || ok "the override skips the route"
grep -qx -- '-4 -br addr show enp9s0' "$LOG/ip_calls" \
  && ok "reads the overridden interface" || bad "reads the overridden interface" "$(cat "$LOG/ip_calls")"
grep '^tether address' "$LOG/out" | grep -q '10.42.0.1/24' \
  && ok "shows the overridden address" || bad "shows the overridden address" "$(cat "$LOG/out")"

# 3. No rndis address: the old name is the last resort.
set_state
: >"$LOG/rndis"
if run; then ok "a phone without rndis still exits 0"; else bad "a phone without rndis still exits 0"; fi
grep -qx -- '-4 -br addr show enp55s0u1' "$LOG/ip_calls" \
  && ok "falls back to the old name" || bad "falls back to the old name" "$(cat "$LOG/ip_calls")"
grep '^tether address' "$LOG/out" | grep -q '10.0.0.1/24' \
  && ok "shows the fallback address" || bad "shows the fallback address" "$(cat "$LOG/out")"

# 4. --help.
if run --help; then ok "--help exits 0"; else bad "--help exits 0"; fi

finish
