#!/usr/bin/env bash
# Hermetic tests for bin/phone-tether-cycle: stub adb with a sys.usb.config
# state and stubbed net-check/tether helpers. No phone, no network.
set -u

BASH_BIN=$(command -v bash)
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/bin/phone-tether-cycle
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
    case "${args[*]}" in
      "getprop sys.usb.config") cat "$LOG/usb" ;;
      "svc usb setFunctions adb")
        printf 'setFunctions adb\n' >>"$LOG/actions"
        printf 'adb\n' >"$LOG/usb"
        ;;
    esac
    ;;
esac
EOF
sed -i "1s|.*|#!$BASH_BIN|" "$STUBS/adb"

cat >"$STUBS/net-check" <<'EOF'
#!/usr/bin/env bash
printf 'net-check\n' >>"$LOG/actions"
printf 'curl:    https://example.com = %s\n' "$(cat "$LOG/health_text")"
exit "$(cat "$LOG/health_rc")"
EOF
sed -i "1s|.*|#!$BASH_BIN|" "$STUBS/net-check"

cat >"$STUBS/phone-usb-tether-default" <<'EOF'
#!/usr/bin/env bash
printf 'tether-default\n' >>"$LOG/actions"
printf 'rndis,adb\n' >"$LOG/usb"
EOF
sed -i "1s|.*|#!$BASH_BIN|" "$STUBS/phone-usb-tether-default"

cat >"$STUBS/phone-usb-tether-check" <<'EOF'
#!/usr/bin/env bash
printf 'tether-check\n' >>"$LOG/actions"
grep -q rndis "$LOG/usb"
EOF
sed -i "1s|.*|#!$BASH_BIN|" "$STUBS/phone-usb-tether-check"

cat >"$TMP/broken-default" <<'EOF'
#!/usr/bin/env bash
printf 'tether-default\n' >>"$LOG/actions"
EOF
sed -i "1s|.*|#!$BASH_BIN|" "$TMP/broken-default"

cat >"$TMP/broken-check" <<'EOF'
#!/usr/bin/env bash
printf 'tether-check\n' >>"$LOG/actions"
exit 1
EOF
sed -i "1s|.*|#!$BASH_BIN|" "$TMP/broken-check"

chmod +x "$STUBS/adb" "$STUBS/net-check" "$STUBS/phone-usb-tether-default" \
  "$STUBS/phone-usb-tether-check" "$TMP/broken-default" "$TMP/broken-check"
export PATH="$STUBS:$PATH"
export PHONE_NET_CHECK=$STUBS/net-check
export PHONE_TETHER_DEFAULT=$STUBS/phone-usb-tether-default
export PHONE_TETHER_CHECK=$STUBS/phone-usb-tether-check

fresh_state() {
  printf 'List of devices attached\nXPLO2EEA0001541\tdevice\n' >"$LOG/devices"
  printf 'rndis,adb\n' >"$LOG/usb"
  printf '200' >"$LOG/health_text"
  printf '0' >"$LOG/health_rc"
  rm -f "$LOG/actions"
  export PHONE_TETHER_DEFAULT=$STUBS/phone-usb-tether-default
  export PHONE_TETHER_CHECK=$STUBS/phone-usb-tether-check
}

run() {
  "$BASH_BIN" "$SCRIPT" "$@" >"$LOG/out" 2>&1
}

# 1. Full cycle with the tether off: health check fails, tether comes back.
fresh_state
printf '000' >"$LOG/health_text"
printf '1' >"$LOG/health_rc"
if run --yes; then
  ok "cycle exits 0 when restored"
else
  bad "cycle exits 0 when restored" "$(cat "$LOG/out")"
fi
order=$(grep -nE 'setFunctions adb|net-check|tether-default|tether-check' "$LOG/actions" | cut -d: -f2 | tr '\n' ' ')
[ "$order" = "setFunctions adb net-check tether-default tether-check " ] \
  && ok "disables, checks, restores, verifies in that order" \
  || bad "disables, checks, restores, verifies in that order" "$order"
grep -q 'disabling USB tethering' "$LOG/out" && ok "reports the disable" \
  || bad "reports the disable" "$(cat "$LOG/out")"
grep -q 'curl:    https://example.com = 000' "$LOG/out" && ok "shows the health check output" \
  || bad "shows the health check output" "$(cat "$LOG/out")"
grep -q 'health check exit 1' "$LOG/out" && ok "reports the failed health check" \
  || bad "reports the failed health check" "$(cat "$LOG/out")"
grep -q 'had no internet while tethering was off' "$LOG/out" && ok "explains the expected outage" \
  || bad "explains the expected outage" "$(cat "$LOG/out")"
grep -q 'route healthy' "$LOG/out" && ok "reports a healthy route" \
  || bad "reports a healthy route" "$(cat "$LOG/out")"

# 2. The laptop keeps internet through another route while the tether is off.
fresh_state
if run --yes; then ok "cycle exits 0 when health passes"; else bad "cycle exits 0 when health passes" "$(cat "$LOG/out")"; fi
grep -q 'kept internet while tethering was off' "$LOG/out" && ok "reports the surviving route" \
  || bad "reports the surviving route" "$(cat "$LOG/out")"

# 3. Already off: no disable command, still checks and restores.
fresh_state
printf 'adb\n' >"$LOG/usb"
if run --yes; then ok "cycle exits 0 when already off"; else bad "cycle exits 0 when already off" "$(cat "$LOG/out")"; fi
grep -q 'setFunctions adb' "$LOG/actions" && bad "does not disable an already-off tether" \
  || ok "does not disable an already-off tether"
grep -q 'tether-default' "$LOG/actions" && ok "still restores the tether" || bad "still restores the tether"

# 4. A restore that does not bring the route back is an error.
fresh_state
export PHONE_TETHER_DEFAULT=$TMP/broken-default
export PHONE_TETHER_CHECK=$TMP/broken-check
if run --yes; then
  bad "unhealthy restore exits 1"
else
  ok "unhealthy restore exits 1"
fi
grep -q 'route is not healthy' "$LOG/out" && ok "explains the unhealthy restore" \
  || bad "explains the unhealthy restore" "$(cat "$LOG/out")"

# 5. Without --yes and no terminal nothing is changed.
fresh_state
if run; then bad "no confirmation exits 1"; else ok "no confirmation exits 1"; fi
[ ! -f "$LOG/actions" ] && ok "no confirmation changes nothing" || bad "no confirmation changes nothing"
grep -q 'aborted' "$LOG/out" && ok "abort is explained" || bad "abort is explained" "$(cat "$LOG/out")"

# 6. No phone.
printf 'List of devices attached\n' >"$LOG/devices"
if run --yes; then bad "no phone exits 1"; else ok "no phone exits 1"; fi
grep -q 'no phone attached' "$LOG/out" && ok "no phone message" || bad "no phone message" "$(cat "$LOG/out")"

# 7. --help exits 0.
if run --help; then ok "--help exits 0"; else bad "--help exits 0"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
