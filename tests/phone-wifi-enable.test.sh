#!/usr/bin/env bash
# Hermetic tests for bin/phone-wifi-enable: stub adb with a wifi_on state.
set -u

BASH_BIN=$(command -v bash)
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/bin/phone-wifi-enable
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
    case "${args[2]:-}" in
      status)
        if [ "$(cat "$LOG/wifi_on")" = 1 ]; then
          printf 'Wifi is enabled\nWifi is not connected\n'
        else
          printf 'Wifi is disabled\n'
        fi
        ;;
      set-wifi-enabled)
        printf 'set-wifi-enabled %s\n' "${args[3]:-}" >>"$LOG/actions"
        if [ "${args[3]:-}" = enabled ]; then printf '1\n' >"$LOG/wifi_on"; else printf '0\n' >"$LOG/wifi_on"; fi
        ;;
    esac
    ;;
esac
EOF
sed -i "1s|.*|#!$BASH_BIN|" "$STUBS/adb"
chmod +x "$STUBS/adb"
export PATH="$STUBS:$PATH"

fresh_state() {
  printf 'List of devices attached\nXPLO2EEA0001541\tdevice\n' >"$LOG/devices"
  printf '1\n' >"$LOG/wifi_on"
  rm -f "$LOG/actions"
}

run() {
  "$BASH_BIN" "$SCRIPT" "$@" >"$LOG/out" 2>&1
}

# 1. Already enabled: --check passes and nothing is set.
fresh_state
if run --check; then
  ok "--check exits 0 when enabled"
else
  bad "--check exits 0 when enabled" "$(cat "$LOG/out")"
fi
[ ! -f "$LOG/actions" ] && ok "--check changes nothing" || bad "--check changes nothing" "$(cat "$LOG/actions")"

# 2. Disabled: --check fails and still changes nothing.
fresh_state
printf '0\n' >"$LOG/wifi_on"
if run --check; then
  bad "--check exits 1 when disabled"
else
  ok "--check exits 1 when disabled"
fi
grep -q 'Wi-Fi is disabled' "$LOG/out" && ok "--check says disabled" \
  || bad "--check says disabled" "$(cat "$LOG/out")"
[ ! -f "$LOG/actions" ] && ok "failed --check changes nothing" || bad "failed --check changes nothing"

# 3. Enabling sets the radio and waits for the state to change.
if run; then
  ok "enable exits 0"
else
  bad "enable exits 0" "$(cat "$LOG/out")"
fi
grep -q 'set-wifi-enabled enabled' "$LOG/actions" && ok "radio is enabled" \
  || bad "radio is enabled" "$(cat "$LOG/actions" 2>/dev/null)"
grep -q 'Wi-Fi enabled' "$LOG/out" && ok "reports success" || bad "reports success" "$(cat "$LOG/out")"
[ "$(cat "$LOG/wifi_on")" = 1 ] && ok "state is on afterwards" || bad "state is on afterwards"

# 4. Enabling is idempotent.
rm -f "$LOG/actions"
if run; then ok "second enable exits 0"; else bad "second enable exits 0" "$(cat "$LOG/out")"; fi
[ ! -f "$LOG/actions" ] && ok "second enable sets nothing" || bad "second enable sets nothing"

# 5. A radio that never comes up is an error.
fresh_state
printf '0\n' >"$LOG/wifi_on"
cat >"$STUBS/adb" <<'EOF'
#!/usr/bin/env bash
args=("$@")
if [ "${args[0]:-}" = "-s" ]; then args=("${args[@]:2}"); fi
case "${args[0]:-}" in
  devices) cat "$LOG/devices" ;;
  shell)
    args=("${args[@]:1}")
    case "${args[2]:-}" in
      status) printf 'Wifi is disabled\n' ;;
      set-wifi-enabled) : ;;
    esac
    ;;
esac
EOF
sed -i "1s|.*|#!$BASH_BIN|" "$STUBS/adb"
chmod +x "$STUBS/adb"
if PHONE_WIFI_TRIES=2 PHONE_WIFI_POLL=1 run; then
  bad "radio that stays off exits 1"
else
  ok "radio that stays off exits 1"
fi
grep -q 'Wi-Fi did not come up' "$LOG/out" && ok "explains the failure" \
  || bad "explains the failure" "$(cat "$LOG/out")"

# 6. No phone.
printf 'List of devices attached\n' >"$LOG/devices"
if run; then bad "no phone exits 1"; else ok "no phone exits 1"; fi
grep -q 'no phone attached' "$LOG/out" && ok "no phone message" || bad "no phone message" "$(cat "$LOG/out")"

# 7. --help exits 0.
if run --help; then ok "--help exits 0"; else bad "--help exits 0"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
