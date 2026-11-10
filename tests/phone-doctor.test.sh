#!/usr/bin/env bash
# Hermetic tests for bin/phone-doctor: stub adb, ip, nmcli, sysctl, systemctl
# and curl. No phone, no network, no root.
set -u

BASH_BIN=$(command -v bash)
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/bin/phone-doctor
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
  devices) cat "$LOG/devices" ;;
  shell)
    args=("${args[@]:1}")
    case "${args[*]}" in
      "dumpsys window policy") printf '  showing=%s\n' "$(cat "$LOG/keyguard")" ;;
      "ip -4 -o addr show rndis0") cat "$LOG/rndis" ;;
      "ip -4 -o addr show"*) cat "$LOG/ips" ;;
      "ip route show default") cat "$LOG/default_route" ;;
      "pm path "*) cat "$LOG/pm" ;;
    esac
    ;;
esac
EOF
sed -i "1s|.*|#!$BASH_BIN|" "$STUBS/adb"

cat >"$STUBS/ip" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "-4 -br addr show "*) cat "$LOG/ap_addr" ;;
  "rule show") cat "$LOG/rules" ;;
esac
EOF
sed -i "1s|.*|#!$BASH_BIN|" "$STUBS/ip"

cat >"$STUBS/nmcli" <<'EOF'
#!/usr/bin/env bash
cat "$LOG/nmcli_cons"
EOF
sed -i "1s|.*|#!$BASH_BIN|" "$STUBS/nmcli"

cat >"$STUBS/sysctl" <<'EOF'
#!/usr/bin/env bash
cat "$LOG/forward"
EOF
sed -i "1s|.*|#!$BASH_BIN|" "$STUBS/sysctl"

cat >"$STUBS/systemctl" <<'EOF'
#!/usr/bin/env bash
cat "$LOG/tunnel"
[ "$(cat "$LOG/tunnel")" = active ]
EOF
sed -i "1s|.*|#!$BASH_BIN|" "$STUBS/systemctl"

cat >"$STUBS/curl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *--socks5-hostname*) printf '%s' "$(cat "$LOG/proxy_code")" ;;
  *) printf '%s' "$(cat "$LOG/internet_code")" ;;
esac
EOF
sed -i "1s|.*|#!$BASH_BIN|" "$STUBS/curl"

chmod +x "$STUBS"/*
export PATH="$STUBS:$PATH"
export PHONE_SECRETS=$TMP/secrets
export PHONE_DOCTOR_RESOLV=$LOG/resolv.conf
printf 'PHONE_SOCKS_PASS=pass\nPHONE_PIN=1234\nPHONE_AP_PASS=pass\n' >"$PHONE_SECRETS"
chmod 600 "$PHONE_SECRETS"

fresh_state() {
  printf 'List of devices attached\nXPLO2EEA0001541\tdevice\n192.168.77.232:5555\tdevice\n' >"$LOG/devices"
  printf 'false\n' >"$LOG/keyguard"
  printf '2: wlan0    inet 192.168.77.232/24 brd 192.168.77.255 scope global wlan0\n3: rndis0    inet 10.9.9.9/24 brd 10.9.9.255 scope global rndis0\n' >"$LOG/ips"
  printf 'default via 10.0.0.1 dev wlan0\n' >"$LOG/default_route"
  printf '3: rndis0    inet 10.9.9.9/24 brd 10.9.9.255 scope global rndis0\n' >"$LOG/rndis"
  printf 'package:/data/app/base.apk\n' >"$LOG/pm"
  printf 'wlp110s0 UP 192.168.77.1/24\n' >"$LOG/ap_addr"
  printf 'phonelink\n' >"$LOG/nmcli_cons"
  printf '1\n' >"$LOG/forward"
  printf 'active\n' >"$LOG/tunnel"
  printf '2022: from all fwmark 0x7e6 lookup 2022\n' >"$LOG/rules"
  printf '200' >"$LOG/proxy_code"
  printf '200' >"$LOG/internet_code"
  printf 'nameserver 1.1.1.1\nnameserver 9.9.9.9\n' >"$LOG/resolv.conf"
}

run() {
  "$BASH_BIN" "$SCRIPT" "$@" >"$LOG/out" 2>&1
}

# 1. Everything in place.
fresh_state
if run; then ok "ready setup exits 0"; else bad "ready setup exits 0" "$(cat "$LOG/out")"; fi
grep -q 'verdict: the whole setup is ready' "$LOG/out" && ok "reports the whole setup ready" \
  || bad "reports the whole setup ready" "$(cat "$LOG/out")"
grep -q '^FAIL' "$LOG/out" && bad "no failures" || ok "no failures"
grep -q 'ok    adb device' "$LOG/out" && ok "reports the adb device" || bad "reports the adb device"
grep -q 'proxy request.*192.168.77.232:1080 -> 200' "$LOG/out" && ok "reports the proxy request" \
  || bad "reports the proxy request" "$(cat "$LOG/out")"
grep -q 'network transport' "$LOG/out" && ok "reports adb over Wi-Fi" || bad "reports adb over Wi-Fi"

# 2. No phone: required failure, phone checks skipped, rest still checked.
fresh_state
printf 'List of devices attached\n' >"$LOG/devices"
if run; then bad "missing phone exits 1"; else ok "missing phone exits 1"; fi
grep -q 'FAIL  adb device' "$LOG/out" && ok "fails the adb condition" || bad "fails the adb condition"
grep -q 'skip  phone address' "$LOG/out" && ok "skips phone checks" || bad "skips phone checks"
grep -q 'ok    https' "$LOG/out" && ok "still checks the internet" || bad "still checks the internet"
grep -q 'setup is not ready' "$LOG/out" && ok "verdict is not ready" || bad "verdict is not ready"

# 3. Locked phone is optional for the proxy but reported.
fresh_state
printf 'true\n' >"$LOG/keyguard"
if run; then ok "locked phone still exits 0"; else bad "locked phone still exits 0" "$(cat "$LOG/out")"; fi
grep -q 'warn  phone unlocked' "$LOG/out" && ok "warns about the keyguard" || bad "warns about the keyguard"
grep -q 'optional condition(s) open' "$LOG/out" && ok "counts the warning" || bad "counts the warning"

# 4. Forwarding off is a required failure.
fresh_state
printf '0\n' >"$LOG/forward"
if run; then bad "forwarding off exits 1"; else ok "forwarding off exits 1"; fi
grep -q 'FAIL  ip_forward' "$LOG/out" && ok "fails ip_forward" || bad "fails ip_forward"

# 5. Hotspot mode: no AP interface, missing AP profile only warns.
fresh_state
: >"$LOG/ap_addr"
: >"$LOG/nmcli_cons"
printf '2: wlan0    inet 10.244.108.165/24 brd 10.244.108.255 scope global wlan0\n' >"$LOG/ips"
if run; then ok "hotspot mode exits 0"; else bad "hotspot mode exits 0" "$(cat "$LOG/out")"; fi
grep -q 'warn  ap profile' "$LOG/out" && ok "warns about the AP profile" || bad "warns about the AP profile"
grep -q 'warn  ap address' "$LOG/out" && ok "warns about the AP address" || bad "warns about the AP address"
grep -q 'proxy request.*10.244.108.165:1080 -> 200' "$LOG/out" && ok "checks the hotspot address" \
  || bad "checks the hotspot address" "$(cat "$LOG/out")"

# 6. A dead proxy is a required failure.
fresh_state
printf '000' >"$LOG/proxy_code"
if run; then bad "dead proxy exits 1"; else ok "dead proxy exits 1"; fi
grep -q 'FAIL  proxy request.*-> 000' "$LOG/out" && ok "fails the proxy request" \
  || bad "fails the proxy request" "$(cat "$LOG/out")"

# 7. Missing secrets: no proxy check, required failures.
fresh_state
if PHONE_SECRETS=$TMP/missing run; then bad "missing secrets exits 1"; else ok "missing secrets exits 1"; fi
grep -q 'FAIL  secrets' "$LOG/out" && ok "fails the secrets condition" || bad "fails the secrets condition"
grep -q 'FAIL  proxy request.*PHONE_SOCKS_PASS' "$LOG/out" && ok "explains the missing password" \
  || bad "explains the missing password" "$(cat "$LOG/out")"

# 8. An inactive tunnel is optional, but its route is not checked then.
fresh_state
printf 'inactive\n' >"$LOG/tunnel"
if run; then ok "inactive tunnel exits 0"; else bad "inactive tunnel exits 0" "$(cat "$LOG/out")"; fi
grep -q 'warn  phone-tun' "$LOG/out" && ok "warns about the tunnel" || bad "warns about the tunnel"
grep -q 'tunnel route' "$LOG/out" && bad "skips the tunnel route" || ok "skips the tunnel route"

# 9. USB tether off only warns.
fresh_state
: >"$LOG/rndis"
if run; then ok "tether off exits 0"; else bad "tether off exits 0" "$(cat "$LOG/out")"; fi
grep -q 'warn  rndis0' "$LOG/out" && ok "warns about the tether" || bad "warns about the tether"

# 10. --help exits 0.
if run --help; then ok "--help exits 0"; else bad "--help exits 0"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
