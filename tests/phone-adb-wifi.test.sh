#!/usr/bin/env bash
# Hermetic tests for bin/phone-adb-wifi: stub adb with a settings/prop state,
# stub avahi-browse with one advertised TLS service. No phone, no network.
set -u

BASH_BIN=$(command -v bash)
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/bin/phone-adb-wifi
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export LOG=$TMP/log STUBS=$TMP/bin HOME=$TMP
mkdir -p "$LOG" "$STUBS"

pass=0
fail=0
ok() {
  pass=$((pass + 1))
  printf 'ok   %s\n' "$*"
}
bad() {
  fail=$((fail + 1))
  printf 'FAIL %s%s\n' "$*" "${2:+ ($2)}"
}

cat >"$STUBS/adb" <<'EOF'
#!/usr/bin/env bash
target=""
args=("$@")
if [ "${args[0]:-}" = "-s" ]; then target=${args[1]}; args=("${args[@]:2}"); fi
case "${args[0]:-}" in
  devices)
    cat "$LOG/devices"
    if [ -f "$LOG/connected" ]; then
      while read -r t; do printf '%s\tdevice\n' "$t"; done <"$LOG/connected"
    fi
    ;;
  connect)
    printf 'connect %s\n' "${args[1]}" >>"$LOG/actions"
    printf '%s\n' "${args[1]}" >>"$LOG/connected"
    ;;
  tcpip)
    printf 'tcpip %s\n' "${args[1]}" >>"$LOG/actions"
    printf '%s' "${args[1]}" >"$LOG/tcp_port"
    ;;
  get-state)
    if [ -n "$target" ] && grep -qx "$target" "$LOG/connected" 2>/dev/null; then
      printf 'device\n'
    else
      printf 'unknown\n'
      exit 1
    fi
    ;;
  shell)
    args=("${args[@]:1}")
    case "${args[*]}" in
      "settings get global adb_wifi_enabled") cat "$LOG/wifi_enabled" ;;
      "settings put global adb_wifi_enabled 1")
        printf 'settings put adb_wifi_enabled\n' >>"$LOG/actions"
        printf '1\n' >"$LOG/wifi_enabled"
        ;;
      "getprop service.adb.tcp.port") cat "$LOG/tcp_port" ;;
      ip\ -4\ -o\ addr\ show*)
        printf '2: wlan0    inet 192.0.2.10/24 brd 192.0.2.255 scope global wlan0\n'
        ;;
    esac
    ;;
esac
EOF
sed -i "1s|.*|#!$BASH_BIN|" "$STUBS/adb"

cat >"$STUBS/avahi-browse" <<'EOF'
#!/usr/bin/env bash
[ -f "$LOG/tls_port" ] || exit 0
port=$(cat "$LOG/tls_port")
[ -n "$port" ] || exit 0
cat <<AVAHI
= wlp110s0 IPv4 adb-XPLO2EEA0001541-test _adb-tls-connect._tcp local
   hostname = [Android.local]
   address = [192.0.2.10]
   port = [$port]
   txt = ["v=ADB_SECURE_SERVICE_VERSION"]
AVAHI
EOF
sed -i "1s|.*|#!$BASH_BIN|" "$STUBS/avahi-browse"

chmod +x "$STUBS/adb" "$STUBS/avahi-browse"
export PATH="$STUBS:$PATH"

fresh_state() {
  printf 'List of devices attached\nXPLO2EEA0001541\tdevice\n' >"$LOG/devices"
  printf '0\n' >"$LOG/wifi_enabled"
  : >"$LOG/tcp_port"
  rm -f "$LOG/actions" "$LOG/connected" "$LOG/tls_port"
  printf '43571' >"$LOG/tls_port"
}

run() {
  "$BASH_BIN" "$SCRIPT" "$@" >"$LOG/out" 2>&1
}

# 1. --check reports and changes nothing.
fresh_state
: >"$LOG/tcp_port"
rm -f "$LOG/tls_port"
if run --check; then ok "--check exits 0"; else bad "--check exits 0" "$(cat "$LOG/out")"; fi
grep -q 'wireless debugging: 0' "$LOG/out" && ok "reports the wireless flag" \
  || bad "reports the wireless flag" "$(cat "$LOG/out")"
grep -q 'legacy tcp port:  not set' "$LOG/out" && ok "reports the legacy port" \
  || bad "reports the legacy port" "$(cat "$LOG/out")"
grep -q 'tls endpoint:     not advertised' "$LOG/out" && ok "reports the missing TLS port" \
  || bad "reports the missing TLS port" "$(cat "$LOG/out")"
[ ! -f "$LOG/actions" ] && ok "--check changes nothing" || bad "--check changes nothing" "$(cat "$LOG/actions")"

# 2. --tls enables the setting and connects to the advertised port.
fresh_state
if run --tls; then ok "--tls exits 0"; else bad "--tls exits 0" "$(cat "$LOG/out")"; fi
grep -q 'settings put adb_wifi_enabled' "$LOG/actions" && ok "enables wireless debugging" \
  || bad "enables wireless debugging" "$(cat "$LOG/actions" 2>/dev/null)"
grep -q 'connect 192.0.2.10:43571' "$LOG/actions" && ok "connects to the TLS port" \
  || bad "connects to the TLS port" "$(cat "$LOG/actions" 2>/dev/null)"
grep -q 'tcpip' "$LOG/actions" && bad "--tls does not touch the legacy port" \
  || ok "--tls does not touch the legacy port"
grep -q 'wireless debugging on 192.0.2.10:43571' "$LOG/out" && ok "reports the TLS endpoint" \
  || bad "reports the TLS endpoint" "$(cat "$LOG/out")"

# 3. --legacy runs tcpip and connects, without enabling wireless debugging.
fresh_state
: >"$LOG/tcp_port"
if run --legacy; then ok "--legacy exits 0"; else bad "--legacy exits 0" "$(cat "$LOG/out")"; fi
grep -q 'tcpip 5555' "$LOG/actions" && ok "sets the legacy port" \
  || bad "sets the legacy port" "$(cat "$LOG/actions" 2>/dev/null)"
grep -q 'connect 192.0.2.10:5555' "$LOG/actions" && ok "connects to the legacy port" \
  || bad "connects to the legacy port" "$(cat "$LOG/actions" 2>/dev/null)"
grep -q 'settings put' "$LOG/actions" && bad "--legacy does not enable wireless debugging" \
  || ok "--legacy does not enable wireless debugging"
grep -q 'legacy adb on 192.0.2.10:5555' "$LOG/out" && ok "reports the legacy endpoint" \
  || bad "reports the legacy endpoint" "$(cat "$LOG/out")"

# 4. Default enables both, wireless first so the adb restart keeps it on.
fresh_state
: >"$LOG/tcp_port"
if run; then ok "default exits 0"; else bad "default exits 0" "$(cat "$LOG/out")"; fi
order=$(grep -nE 'settings put|tcpip|connect' "$LOG/actions" | sed 's/^[0-9]*://' | tr '\n' ' ')
case $order in
  "settings put adb_wifi_enabled tcpip 5555 connect 192.0.2.10:5555 connect 192.0.2.10:43571 ") ;;
  *) bad "enables then connects to both" "$order" ;;
esac
grep -q 'connect 192.0.2.10:43571' "$LOG/actions" && ok "connects to both ports" \
  || bad "connects to both ports" "$(cat "$LOG/actions" 2>/dev/null)"

# 5. Already enabled: no toggle and no adb restart.
fresh_state
printf '1\n' >"$LOG/wifi_enabled"
printf '5555' >"$LOG/tcp_port"
if run; then ok "second run exits 0"; else bad "second run exits 0" "$(cat "$LOG/out")"; fi
grep -q 'settings put' "$LOG/actions" && bad "does not toggle again" \
  || ok "does not toggle again"
grep -q 'tcpip' "$LOG/actions" && bad "does not restart adbd again" \
  || ok "does not restart adbd again"
grep -q 'connect 192.0.2.10:5555' "$LOG/actions" && ok "still connects to the legacy port" \
  || bad "still connects to the legacy port" "$(cat "$LOG/actions" 2>/dev/null)"

# 6. Wireless debugging requested but nothing advertised is an error.
fresh_state
rm -f "$LOG/tls_port"
if run --tls; then bad "missing TLS port exits 1"; else ok "missing TLS port exits 1"; fi
grep -q 'did not become reachable' "$LOG/out" && ok "explains the missing port" \
  || bad "explains the missing port" "$(cat "$LOG/out")"

# 7. No phone.
printf 'List of devices attached\n' >"$LOG/devices"
if run --check; then bad "no phone exits 1"; else ok "no phone exits 1"; fi
grep -q 'no phone attached' "$LOG/out" && ok "no phone message" || bad "no phone message" "$(cat "$LOG/out")"

# 8. --help exits 0.
if run --help; then ok "--help exits 0"; else bad "--help exits 0"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
