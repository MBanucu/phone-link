#!/usr/bin/env bash
# Hermetic tests for bin/phone-tether-cycle: stub adb with a sys.usb.config
# state, stubbed net-check/phone-unlock/tether-check helpers. No phone.
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
      "dumpsys window policy") printf '  showing=true\n' ;;
      "input keyevent KEYCODE_SLEEP") printf 'sleep\n' >>"$LOG/actions" ;;
      "svc usb setScreenUnlockedFunctions rndis,adb")
        printf 'screen rndis,adb\n' >>"$LOG/actions"
        ;;
      "svc usb setFunctions")
        printf 'charging\n' >>"$LOG/actions"
        printf 'adb\n' >"$LOG/usb"
        ;;
      "svc usb setFunctions mtp")
        printf 'setFunctions mtp\n' >>"$LOG/actions"
        if [ -f "$LOG/fail_once" ]; then
          rm -f "$LOG/fail_once"
          exit 137
        fi
        printf 'mtp,adb\n' >"$LOG/usb"
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

cat >"$STUBS/phone-unlock" <<'EOF'
#!/usr/bin/env bash
printf 'unlock\n' >>"$LOG/actions"
# Unlocking is what makes the phone apply the screen-unlocked functions.
printf 'rndis,adb\n' >"$LOG/usb"
EOF
sed -i "1s|.*|#!$BASH_BIN|" "$STUBS/phone-unlock"

cat >"$STUBS/phone-usb-tether-check" <<'EOF'
#!/usr/bin/env bash
printf 'tether-check\n' >>"$LOG/actions"
grep -q rndis "$LOG/usb"
EOF
sed -i "1s|.*|#!$BASH_BIN|" "$STUBS/phone-usb-tether-check"

cat >"$TMP/broken-check" <<'EOF'
#!/usr/bin/env bash
printf 'tether-check\n' >>"$LOG/actions"
exit 1
EOF
sed -i "1s|.*|#!$BASH_BIN|" "$TMP/broken-check"

chmod +x "$STUBS/adb" "$STUBS/net-check" "$STUBS/phone-unlock" \
  "$STUBS/phone-usb-tether-check" "$TMP/broken-check"
export PATH="$STUBS:$PATH"
export PHONE_NET_CHECK=$STUBS/net-check
export PHONE_UNLOCK=$STUBS/phone-unlock
export PHONE_TETHER_CHECK=$STUBS/phone-usb-tether-check
export PHONE_DISABLE_TRIES=5
export PHONE_RESTORE_TRIES=1
export PHONE_RESTORE_WAIT=0

fresh_state() {
  printf 'List of devices attached\nXPLO2EEA0001541\tdevice\n' >"$LOG/devices"
  printf 'rndis,adb\n' >"$LOG/usb"
  printf '200' >"$LOG/health_text"
  printf '0' >"$LOG/health_rc"
  rm -f "$LOG/actions" "$LOG/fail_once"
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
order=$(grep -nE 'setFunctions mtp|net-check|screen rndis,adb|charging|sleep|unlock|tether-check' "$LOG/actions" | cut -d: -f2 | tr '\n' ' ')
[ "$order" = "setFunctions mtp net-check screen rndis,adb charging sleep unlock tether-check " ] \
  && ok "disables, checks, then locks, unlocks and verifies in that order" \
  || bad "disables, checks, then locks, unlocks and verifies in that order" "$order"
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

# 3. A crashing adb client on the first setter is retried.
fresh_state
: >"$LOG/fail_once"
if run --yes; then
  ok "survives an adb abort during disable"
else
  bad "survives an adb abort during disable" "$(cat "$LOG/out")"
fi
[ "$(grep -c 'setFunctions mtp' "$LOG/actions")" -ge 2 ] && ok "reissues the setter" \
  || bad "reissues the setter" "$(cat "$LOG/actions")"
grep -q 'net-check' "$LOG/actions" && ok "health check still runs" || bad "health check still runs"
grep -q 'route healthy' "$LOG/out" && ok "tether is healthy afterwards" \
  || bad "tether is healthy afterwards" "$(cat "$LOG/out")"

# 4. Already off: no disable command, still locks, unlocks and verifies.
fresh_state
printf 'mtp,adb\n' >"$LOG/usb"
if run --yes; then ok "cycle exits 0 when already off"; else bad "cycle exits 0 when already off" "$(cat "$LOG/out")"; fi
grep -q 'setFunctions mtp' "$LOG/actions" && bad "does not disable an already-off tether" \
  || ok "does not disable an already-off tether"
grep -q 'unlock' "$LOG/actions" && ok "still restores the tether" || bad "still restores the tether"
grep -q 'tether-check' "$LOG/actions" && ok "still verifies the tether" || bad "still verifies the tether"

# 5. A restore that does not bring the route back is an error.
fresh_state
export PHONE_TETHER_CHECK=$TMP/broken-check
if run --yes; then
  bad "unhealthy restore exits 1"
else
  ok "unhealthy restore exits 1"
fi
grep -q 'could not restore USB tethering' "$LOG/out" && ok "explains the failed restore" \
  || bad "explains the failed restore" "$(cat "$LOG/out")"

# 6. Without --yes and no terminal nothing is changed.
fresh_state
if run; then bad "no confirmation exits 1"; else ok "no confirmation exits 1"; fi
[ ! -f "$LOG/actions" ] && ok "no confirmation changes nothing" || bad "no confirmation changes nothing"
grep -q 'aborted' "$LOG/out" && ok "abort is explained" || bad "abort is explained" "$(cat "$LOG/out")"

# 7. No phone.
printf 'List of devices attached\n' >"$LOG/devices"
if run --yes; then bad "no phone exits 1"; else ok "no phone exits 1"; fi
grep -q 'no phone attached' "$LOG/out" && ok "no phone message" || bad "no phone message" "$(cat "$LOG/out")"

# 8. --help exits 0.
if run --help; then ok "--help exits 0"; else bad "--help exits 0"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
