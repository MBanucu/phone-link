#!/usr/bin/env bash
# Hermetic tests for bin/phone-usb-tether-check: stub adb for the phone side,
# stub ip for host routes and a stub curl for the request. No phone, no network.
set -u

BASH_BIN=$(command -v bash)
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/bin/phone-usb-tether-check
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
args=("$@")
if [ "${args[0]:-}" = "-s" ]; then args=("${args[@]:2}"); fi
case "${args[0]:-}" in
  devices) cat "$LOG/devices" ;;
  shell)
    args=("${args[@]:1}")
    case "${args[0]:-}" in
      ip) cat "$LOG/rndis" ;;
      getprop) cat "$LOG/usbconfig" ;;
      dumpsys) cat "$LOG/tethering" ;;
    esac
    ;;
esac
EOF
sed -i "1s|.*|#!$BASH_BIN|" "$STUBS/adb"

cat >"$STUBS/ip" <<'EOF'
#!/usr/bin/env bash
# Only `ip -o route get <ip>` is used by the script.
if [ -f "$LOG/route" ]; then
  cat "$LOG/route"
else
  echo "RTNETLINK answers: Network is unreachable" >&2
  exit 2
fi
EOF
sed -i "1s|.*|#!$BASH_BIN|" "$STUBS/ip"

cat >"$STUBS/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s' "$*" >"$LOG/curl.argv"
printf '%s' "$(cat "$LOG/code" 2>/dev/null || echo 000)"
EOF
sed -i "1s|.*|#!$BASH_BIN|" "$STUBS/curl"

chmod +x "$STUBS/adb" "$STUBS/ip" "$STUBS/curl"
export PATH="$STUBS:$PATH"

set_state() {
  printf 'List of devices attached\nXPLO2EEA0001541\tdevice\n' >"$LOG/devices"
  printf '53: rndis0    inet 172.26.192.42/24 brd 172.26.192.255 scope global rndis0\n' >"$LOG/rndis"
  printf 'rndis,adb\n' >"$LOG/usbconfig"
  printf '      rndis0 - TetheredState - lastError = 0\n' >"$LOG/tethering"
  printf '172.26.192.42 dev enp55s0u1 src 172.26.192.210 uid 1000\n' >"$LOG/route"
  printf '200' >"$LOG/code"
  rm -f "$LOG/curl.argv"
}

run() {
  "$BASH_BIN" "$SCRIPT" "$@" >"$LOG/out" 2>&1
}

# 1. Active USB tethering with internet over the route.
set_state
if run; then
  ok "active tether exits 0"
else
  bad "active tether exits 0" "$(cat "$LOG/out")"
fi
grep -q 'USB tethering active: rndis0 172.26.192.42/24' "$LOG/out" && ok "reports the phone address" \
  || bad "reports the phone address" "$(cat "$LOG/out")"
grep -q 'host:     enp55s0u1 with 172.26.192.210, route via 172.26.192.42' "$LOG/out" \
  && ok "reports the host interface and source" || bad "reports the host interface and source" "$(cat "$LOG/out")"
grep -q 'internet: https://example.com over 172.26.192.210 = 200' "$LOG/out" \
  && ok "reports the request result" || bad "reports the request result" "$(cat "$LOG/out")"
grep -q -- '--interface 172.26.192.210' "$LOG/curl.argv" && ok "request is bound to the tether source" \
  || bad "request is bound to the tether source" "$(cat "$LOG/curl.argv" 2>/dev/null)"
grep -q 'verdict:  USB tethering is active and reaches the internet' "$LOG/out" \
  && ok "verdict says active and online" || bad "verdict says active and online" "$(cat "$LOG/out")"

# 2. No rndis address: tethering off, and no host or curl calls.
set_state
: >"$LOG/rndis"
if run; then
  bad "no rndis address exits 1"
else
  ok "no rndis address exits 1"
fi
grep -q 'USB tethering is not active' "$LOG/out" && ok "explains rndis0 is unaddressed" \
  || bad "explains rndis0 is unaddressed" "$(cat "$LOG/out")"
[ ! -f "$LOG/curl.argv" ] && ok "no request without a tether" || bad "no request without a tether"

# 3. Address exists but RNDIS is not the selected USB function.
set_state
printf 'mtp,adb\n' >"$LOG/usbconfig"
printf '      rndis0 - IdleState - lastError = 0\n' >"$LOG/tethering"
if run; then
  bad "idle usb function exits 1"
else
  ok "idle usb function exits 1"
fi
grep -q 'USB tethering is not enabled' "$LOG/out" && ok "explains the usb function" \
  || bad "explains the usb function" "$(cat "$LOG/out")"

# 4. Phone tethers but the host has no route.
set_state
rm -f "$LOG/route"
if run; then
  bad "missing host route exits 1"
else
  ok "missing host route exits 1"
fi
grep -q 'no route to 172.26.192.42' "$LOG/out" && ok "reports the missing route" \
  || bad "reports the missing route" "$(cat "$LOG/out")"
[ ! -f "$LOG/curl.argv" ] && ok "no request without a host route" || bad "no request without a host route"

# 5. Route works but the request fails.
set_state
printf '000' >"$LOG/code"
if run; then
  bad "failed request exits 1"
else
  ok "failed request exits 1"
fi
grep -q 'no internet over it (HTTP 000)' "$LOG/out" && ok "explains the failed request" \
  || bad "explains the failed request" "$(cat "$LOG/out")"

# 6. No phone attached.
printf 'List of devices attached\n' >"$LOG/devices"
if run; then
  bad "no phone exits 1"
else
  ok "no phone exits 1"
fi
grep -q 'no phone attached' "$LOG/out" && ok "no phone message" || bad "no phone message" "$(cat "$LOG/out")"

# 7. --help exits 0.
if run --help; then ok "--help exits 0"; else bad "--help exits 0"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
