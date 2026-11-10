#!/usr/bin/env bash
# Hermetic tests for bin/phone-usb-tether-default: stub adb with svc usb and
# sys.usb.config state. No phone.
set -u

BASH_BIN=$(command -v bash)
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/bin/phone-usb-tether-default
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
render_screen() { cat "$LOG/screen"; }
case "${args[0]:-}" in
  devices) cat "$LOG/devices" ;;
  shell)
    args=("${args[@]:1}")
    case "${args[0]:-}" in
      getprop) cat "$LOG/usbconfig" ;;
      dumpsys) printf '        screen_unlocked_functions=%s\n' "$(cat "$LOG/screen")" ;;
      svc)
        case "${args[2]:-}" in
          getFunctions) cat "$LOG/functions" ;;
          setFunctions)
            printf 'setFunctions %s\n' "${args[3]:-}" >>"$LOG/actions"
            if [ -f "$LOG/fail_once" ]; then
              rm -f "$LOG/fail_once"
              exit 137
            fi
            printf 'rndis,adb\n' >"$LOG/usbconfig"
            ;;
          setScreenUnlockedFunctions)
            printf 'setScreenUnlockedFunctions %s\n' "${args[3]:-}" >>"$LOG/actions"
            printf 'RNDIS\n' >"$LOG/screen"
            ;;
        esac
        ;;
    esac
    ;;
esac
EOF
sed -i "1s|.*|#!$BASH_BIN|" "$STUBS/adb"
chmod +x "$STUBS/adb"
export PATH="$STUBS:$PATH"
export PHONE_TETHER_TRIES=1

reset_state() {
  printf 'List of devices attached\nXPLO2EEA0001541\tdevice\n' >"$LOG/devices"
  printf 'rndis\n' >"$LOG/functions"
  printf 'rndis,adb\n' >"$LOG/usbconfig"
  printf 'RNDIS\n' >"$LOG/screen"
  rm -f "$LOG/actions"
}

run() {
  "$BASH_BIN" "$SCRIPT" "$@" >"$LOG/out" 2>&1
}

# 1. Already the default: --check passes and changes nothing.
reset_state
if run --check; then
  ok "--check exits 0 when already default"
else
  bad "--check exits 0 when already default" "$(cat "$LOG/out")"
fi
grep -q 'current:  rndis,adb' "$LOG/out" && ok "reports the current functions" \
  || bad "reports the current functions" "$(cat "$LOG/out")"
grep -q 'default:  RNDIS' "$LOG/out" && ok "reports the screen-unlocked default" \
  || bad "reports the screen-unlocked default" "$(cat "$LOG/out")"
[ ! -f "$LOG/actions" ] && ok "--check changes nothing" || bad "--check changes nothing" "$(cat "$LOG/actions")"

# 2. Charging only: --check fails, still changes nothing.
reset_state
printf 'none\n' >"$LOG/functions"
printf 'adb\n' >"$LOG/usbconfig"
printf 'RNDIS\n' >"$LOG/screen"
if run --check; then
  bad "--check exits 1 when tethering is off"
else
  ok "--check exits 1 when tethering is off"
fi
grep -q 'verdict:  USB tethering is not the default USB action' "$LOG/out" \
  && ok "verdict says not default" || bad "verdict says not default" "$(cat "$LOG/out")"
[ ! -f "$LOG/actions" ] && ok "failed --check changes nothing" || bad "failed --check changes nothing"

# 3. Apply from charging-only: both knobs are set.
reset_state
printf 'none\n' >"$LOG/functions"
printf 'adb\n' >"$LOG/usbconfig"
printf 'none\n' >"$LOG/screen"
if run; then
  ok "apply exits 0"
else
  bad "apply exits 0" "$(cat "$LOG/out")"
fi
grep -q 'setFunctions rndis,adb' "$LOG/actions" && ok "sets current functions" \
  || bad "sets current functions" "$(cat "$LOG/actions" 2>/dev/null)"
grep -q 'setScreenUnlockedFunctions rndis,adb' "$LOG/actions" && ok "sets the default action" \
  || bad "sets the default action" "$(cat "$LOG/actions" 2>/dev/null)"
grep -q 'USB tethering is now the default USB action' "$LOG/out" && ok "reports success" \
  || bad "reports success" "$(cat "$LOG/out")"

# 4. Current tethering but no default: only the default is set.
reset_state
printf 'none\n' >"$LOG/screen"
printf 'maybe\n' >"$LOG/functions"
if run; then
  ok "apply with tether up exits 0"
else
  bad "apply with tether up exits 0" "$(cat "$LOG/out")"
fi
grep -q 'setFunctions' "$LOG/actions" && bad "does not touch current functions" \
  || ok "does not touch current functions"
grep -q 'setScreenUnlockedFunctions rndis,adb' "$LOG/actions" && ok "sets the default action" \
  || bad "sets the default action"

# 5b. An adb abort during the setter is retried.
reset_state
printf 'none\n' >"$LOG/functions"
printf 'adb\n' >"$LOG/usbconfig"
printf 'none\n' >"$LOG/screen"
: >"$LOG/fail_once"
if run; then
  ok "survives an adb abort while setting the tether"
else
  bad "survives an adb abort while setting the tether" "$(cat "$LOG/out")"
fi
grep -q 'USB tethering is now the default USB action' "$LOG/out" && ok "reports success after the abort" \
  || bad "reports success after the abort" "$(cat "$LOG/out")"
[ "$(grep -c 'setFunctions rndis,adb' "$LOG/actions")" -ge 2 ] && ok "reissues the setter" \
  || bad "reissues the setter" "$(cat "$LOG/actions")"

# 5. Setters that do not take effect are an error.
reset_state
printf 'none\n' >"$LOG/functions"
printf 'adb\n' >"$LOG/usbconfig"
# Make setFunctions a no-op by overriding the stub for this case.
cat >"$STUBS/adb" <<'EOF'
#!/usr/bin/env bash
args=("$@")
if [ "${args[0]:-}" = "-s" ]; then args=("${args[@]:2}"); fi
case "${args[0]:-}" in
  devices) cat "$LOG/devices" ;;
  shell)
    args=("${args[@]:1}")
    case "${args[0]:-}" in
      getprop) cat "$LOG/usbconfig" ;;
      dumpsys) printf '        screen_unlocked_functions=RNDIS\n' ;;
      svc)
        case "${args[2]:-}" in
          getFunctions) cat "$LOG/functions" ;;
        esac
        ;;
    esac
    ;;
esac
EOF
sed -i "1s|.*|#!$BASH_BIN|" "$STUBS/adb"
chmod +x "$STUBS/adb"
if run; then
  bad "unapplied setter exits 1"
else
  ok "unapplied setter exits 1"
fi
grep -q 'did not become current' "$LOG/out" && ok "explains the failure" \
  || bad "explains the failure" "$(cat "$LOG/out")"

# 6. No phone.
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
