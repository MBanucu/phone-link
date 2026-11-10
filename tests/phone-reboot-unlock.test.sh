#!/usr/bin/env bash
# Hermetic tests for bin/phone-reboot-unlock: stub adb that goes offline and
# comes back, stub phone-unlock. No phone.
set -u

BASH_BIN=$(command -v bash)
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/bin/phone-reboot-unlock
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
  reboot)
    printf 'reboot\n' >>"$LOG/actions"
    : >"$LOG/online"
    if [ ! -f "$LOG/no_boot" ]; then
      ( sleep "$(cat "$LOG/boot_delay" 2>/dev/null || echo 1)"; : >"$LOG/booted" ) &
    fi
    ;;
  get-state)
    if [ -f "$LOG/online" ]; then
      printf 'device\n'
    else
      printf 'unknown\n'
      exit 1
    fi
    ;;
  shell)
    args=("${args[@]:1}")
    case "${args[0]:-}" in
      getprop)
        if [ "${args[1]:-}" = sys.boot_completed ] && [ -f "$LOG/booted" ]; then
          printf '1\n'
        else
          printf '0\n'
        fi
        ;;
    esac
    ;;
esac
EOF
sed -i "1s|.*|#!$BASH_BIN|" "$STUBS/adb"

cat >"$STUBS/phone-unlock" <<'EOF'
#!/usr/bin/env bash
printf 'unlock\n' >>"$LOG/actions"
EOF
sed -i "1s|.*|#!$BASH_BIN|" "$STUBS/phone-unlock"
chmod +x "$STUBS/adb" "$STUBS/phone-unlock"
export PATH="$STUBS:$PATH"

run() {
  PHONE_REBOOT_POLL=1 PHONE_REBOOT_TIMEOUT="${REBOOT_TIMEOUT:-3}" \
    "$BASH_BIN" "$SCRIPT" "$@" >"$LOG/out" 2>&1
}

fresh_state() {
  printf 'List of devices attached\nXPLO2EEA0001541\tdevice\n' >"$LOG/devices"
  rm -f "$LOG/actions" "$LOG/online" "$LOG/booted" "$LOG/no_boot" "$LOG/boot_delay"
}

# 1. --yes reboots, waits for device and boot, then unlocks.
fresh_state
if run --yes; then
  ok "reboot exits 0"
else
  bad "reboot exits 0" "$(cat "$LOG/out")"
fi
grep -q 'reboot' "$LOG/actions" && ok "phone rebooted" || bad "phone rebooted" "$(cat "$LOG/out")"
grep -q 'unlock' "$LOG/actions" && ok "phone unlocked" || bad "phone unlocked" "$(cat "$LOG/out")"
grep -q 'rebooting XPLO2EEA0001541' "$LOG/out" && ok "reports the reboot" \
  || bad "reports the reboot" "$(cat "$LOG/out")"
grep -q 'phone rebooted and unlocked' "$LOG/out" && ok "reports completion" \
  || bad "reports completion" "$(cat "$LOG/out")"

# 2. Boot takes a moment: the wait loop is not a one-shot check.
fresh_state
printf '2\n' >"$LOG/boot_delay"
if REBOOT_TIMEOUT=10 run --yes; then
  ok "waits for a slow boot"
else
  bad "waits for a slow boot" "$(cat "$LOG/out")"
fi
grep -q 'unlock' "$LOG/actions" && ok "slow boot still unlocks" || bad "slow boot still unlocks"

# 3. Without --yes and no terminal, nothing is rebooted.
fresh_state
if run; then
  bad "no confirmation exits 1"
else
  ok "no confirmation exits 1"
fi
[ ! -f "$LOG/actions" ] && ok "no confirmation reboots nothing" || bad "no confirmation reboots nothing"
grep -q 'aborted' "$LOG/out" && ok "abort is explained" || bad "abort is explained" "$(cat "$LOG/out")"

# 4. The phone never finishes booting.
fresh_state
: >"$LOG/no_boot"
if REBOOT_TIMEOUT=2 run --yes; then
  bad "boot timeout exits 1"
else
  ok "boot timeout exits 1"
fi
grep -q 'did not finish booting' "$LOG/out" && ok "timeout is explained" \
  || bad "timeout is explained" "$(cat "$LOG/out")"

# 5. No phone.
printf 'List of devices attached\n' >"$LOG/devices"
if run --yes; then
  bad "no phone exits 1"
else
  ok "no phone exits 1"
fi
grep -q 'no phone attached' "$LOG/out" && ok "no phone message" || bad "no phone message" "$(cat "$LOG/out")"

# 6. --help exits 0.
if run --help; then ok "--help exits 0"; else bad "--help exits 0"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
