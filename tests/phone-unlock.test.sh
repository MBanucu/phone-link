#!/usr/bin/env bash
# Hermetic tests for bin/phone-unlock: stub adb, no phone.
set -u

BASH_BIN=$(command -v bash)
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/bin/phone-unlock
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export LOG=$TMP/log STUBS=$TMP/bin HOME=$TMP PHONE_SECRETS=$TMP/secrets
mkdir -p "$LOG" "$STUBS"
printf 'PHONE_SOCKS_PASS=unused\n' >"$PHONE_SECRETS"

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
screen() { cat "$LOG/screen" 2>/dev/null || printf 'on\n'; }
case "${args[0]:-}" in
  devices) printf 'List of devices attached\nXPLO2EEA0001541\tdevice\n' ;;
  shell)
    args=("${args[@]:1}")
    case "${args[0]:-}" in
      wm)
        printf '%s\n' "${args[*]}" >>"$LOG/wm.log"
        printf 'Physical size: 1440x3200\n'
        ;;
      dumpsys)
        printf '  showing=%s\n' "$(cat "$LOG/keyguard")"
        if [ "$(screen)" = off ]; then
          printf '  screenState=SCREEN_STATE_OFF\n  interactiveState=INTERACTIVE_STATE_SLEEP\n'
        else
          printf '  screenState=SCREEN_STATE_ON\n  interactiveState=INTERACTIVE_STATE_AWAKE\n'
        fi
        ;;
      input)
        args=("${args[@]:1}")
        printf '%s\n' "${args[*]}" >>"$LOG/input.log"
        if [ "${args[0]:-}" = keyevent ] && [ "${args[1]:-}" = KEYCODE_WAKEUP ]; then
          printf 'on\n' >"$LOG/screen"
        fi
        if [ "${args[0]:-}" = text ] && [ "${args[1]:-}" = "${PHONE_TEST_PIN:-}" ]; then
          printf 'false\n' >"$LOG/keyguard"
        fi
        ;;
      *) : ;;
    esac
    ;;
esac
EOF
sed -i "1s|.*|#!$BASH_BIN|" "$STUBS/adb"
chmod +x "$STUBS/adb"
export PHONE_TEST_PIN=2468
export PATH="$STUBS:$PATH"

run() {
  PHONE_PIN="${PIN-}" "$BASH_BIN" "$SCRIPT" "$@" >"$LOG/out" 2>&1
}

# 1. --check on a locked phone is read-only and fails.
printf 'true\n' >"$LOG/keyguard"
rm -f "$LOG/input.log"
if run --check; then
  bad "--check exits 1 while locked"
else
  ok "--check exits 1 while locked"
fi
grep -q 'phone is locked' "$LOG/out" && ok "--check says the phone is locked" \
  || bad "--check says the phone is locked" "$(cat "$LOG/out")"
[ ! -f "$LOG/input.log" ] && ok "--check sends no input" || bad "--check sends no input"

# 2. A wrong PIN leaves the keyguard up and exits 1.
printf 'true\n' >"$LOG/keyguard"
if PIN=0000 run; then
  bad "wrong PIN exits 1"
else
  ok "wrong PIN exits 1"
fi
[ "$(cat "$LOG/keyguard")" = true ] && ok "wrong PIN leaves the phone locked" \
  || bad "wrong PIN leaves the phone locked"
grep -q 'text 0000' "$LOG/input.log" && ok "wrong PIN is typed" || bad "wrong PIN is typed"
grep -q 'still locked' "$LOG/out" && ok "wrong PIN reports the failure" \
  || bad "wrong PIN reports the failure" "$(cat "$LOG/out")"

# 3. The right PIN unlocks and the script verifies it.
printf 'true\n' >"$LOG/keyguard"
rm -f "$LOG/input.log"
if PIN=2468 run; then
  ok "correct PIN exits 0"
else
  bad "correct PIN exits 0" "$(cat "$LOG/out")"
fi
[ "$(cat "$LOG/keyguard")" = false ] && ok "correct PIN unlocks the phone" \
  || bad "correct PIN unlocks the phone"
for want in 'KEYCODE_WAKEUP' 'swipe 720 2496 720 704 250' 'text 2468' 'KEYCODE_ENTER'; do
  grep -qF "$want" "$LOG/input.log" && ok "input sequence has: $want" \
    || bad "input sequence has: $want" "$(cat "$LOG/input.log")"
done
grep -q 'unlocked' "$LOG/out" && ok "unlock is confirmed" || bad "unlock is confirmed"

# 4. An unlocked phone is left alone.
printf 'false\n' >"$LOG/keyguard"
rm -f "$LOG/input.log"
if run; then
  ok "already unlocked exits 0"
else
  bad "already unlocked exits 0"
fi
[ ! -f "$LOG/input.log" ] && ok "already unlocked sends no input" || bad "already unlocked sends no input"

# 5. A sleeping phone is woken before the PIN is typed, and says so.
printf 'false\n' >"$LOG/keyguard"
printf 'off\n' >"$LOG/screen"
rm -f "$LOG/input.log"
if run --check; then
  bad "--check exits 1 while asleep"
else
  ok "--check exits 1 while asleep"
fi
grep -q 'phone is asleep' "$LOG/out" && ok "--check says the phone is asleep" \
  || bad "--check says the phone is asleep" "$(cat "$LOG/out")"
[ ! -f "$LOG/input.log" ] && ok "--check sends no input while asleep" \
  || bad "--check sends no input while asleep"
if PIN=2468 run; then
  ok "a sleeping phone is woken and unlocked"
else
  bad "a sleeping phone is woken and unlocked" "$(cat "$LOG/out")"
fi
[ "$(cat "$LOG/screen")" = on ] && ok "the screen is left awake" || bad "the screen is left awake"
grep -q 'KEYCODE_WAKEUP' "$LOG/input.log" && ok "the wake key is sent" \
  || bad "the wake key is sent"

# 6. A failed unlock is retried instead of giving up after one swipe.
printf 'true\n' >"$LOG/keyguard"
printf 'on\n' >"$LOG/screen"
rm -f "$LOG/input.log"
if PIN=0000 run; then
  bad "repeated wrong PIN exits 1"
else
  ok "repeated wrong PIN exits 1"
fi
[ "$(grep -cF 'text 0000' "$LOG/input.log")" -eq 3 ] && ok "a wrong PIN is retried three times" \
  || bad "a wrong PIN is retried three times" "$(cat "$LOG/input.log")"

# 7. The PIN can come from the secrets file instead of the environment.
printf 'PHONE_PIN=2468\n' >"$PHONE_SECRETS"
printf 'true\n' >"$LOG/keyguard"
if env -u PHONE_PIN PATH="$PATH" HOME="$HOME" PHONE_SECRETS="$PHONE_SECRETS" \
  "$BASH_BIN" "$SCRIPT" >"$LOG/out" 2>&1; then
  ok "PIN from PHONE_SECRETS works"
else
  bad "PIN from PHONE_SECRETS works" "$(cat "$LOG/out")"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
