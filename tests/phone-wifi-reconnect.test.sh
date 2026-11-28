#!/usr/bin/env bash
# Hermetic tests for bin/phone-wifi-reconnect: stub adb with two global
# settings. No phone, no root, no network.
set -u

BASH_BIN=$(command -v bash)
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/bin/phone-wifi-reconnect
. "$ROOT/tests/lib/harness.sh"
suite
# Never consult a real phone or avahi in the sandbox.
export PHONE_ADB_MDNS=0
unset PHONE_SERIAL


stub adb
answer adb <<'EOF'
printf '%s\n' "$*" >>"$LOG/adb.log"
args=("$@")
if [ "${args[0]:-}" = "-s" ]; then args=("${args[@]:2}"); fi
cmd="${args[*]}"
last=${args[${#args[@]}-1]}
case "$cmd" in
  devices) cat "$LOG/devices" ;;
  "shell settings get global network_avoid_bad_wifi") cat "$LOG/avoid" ;;
  "shell settings get global wifi_always_requested") cat "$LOG/always" ;;
  "shell settings put global network_avoid_bad_wifi "*) printf '%s\n' "$last" >"$LOG/avoid" ;;
  "shell settings put global wifi_always_requested "*) printf '%s\n' "$last" >"$LOG/always" ;;
esac
EOF

run() {
  "$BASH_BIN" "$SCRIPT" "$@" >"$LOG/out" 2>&1
}

fresh() {
  printf 'List of devices attached\nXPLO2EEA0001541\tdevice\n' >"$LOG/devices"
  printf '0\n' >"$LOG/avoid"
  printf '1\n' >"$LOG/always"
  : >"$LOG/adb.log"
}

# 1. --check with both recommended values is clean and writes nothing.
fresh
if run --check; then ok "--check on recommended values exits 0"; else bad "--check on recommended values exits 0" "$(cat "$LOG/out")"; fi
grep -q 'network_avoid_bad_wifi: 0 (recommended)' "$LOG/out" \
  && ok "reports network_avoid_bad_wifi" || bad "reports network_avoid_bad_wifi" "$(cat "$LOG/out")"
grep -q 'wifi_always_requested: 1 (recommended)' "$LOG/out" \
  && ok "reports wifi_always_requested" || bad "reports wifi_always_requested" "$(cat "$LOG/out")"
grep -q ' settings put ' "$LOG/adb.log" && bad "--check writes nothing" \
  || ok "--check writes nothing"

# 2. --check with one mismatch exits 1 and still writes nothing.
fresh
printf '1\n' >"$LOG/avoid"
if run --check; then bad "--check on a mismatch exits 1"; else ok "--check on a mismatch exits 1"; fi
grep -q 'network_avoid_bad_wifi: 1 (want 0)' "$LOG/out" \
  && ok "names the mismatched value" || bad "names the mismatched value" "$(cat "$LOG/out")"
grep -q 'not applied (run phone-wifi-reconnect' "$LOG/out" \
  && ok "says nothing was applied" || bad "says nothing was applied" "$(cat "$LOG/out")"
grep -q ' settings put ' "$LOG/adb.log" && bad "a mismatch check writes nothing" \
  || ok "a mismatch check writes nothing"

# 3. Applying from stock writes both, re-reads them and reports the result.
fresh
printf '1\n' >"$LOG/avoid"
printf '0\n' >"$LOG/always"
if run; then ok "apply exits 0"; else bad "apply exits 0" "$(cat "$LOG/out")"; fi
grep -q 'settings put global network_avoid_bad_wifi 0' "$LOG/adb.log" \
  && ok "writes network_avoid_bad_wifi=0" || bad "writes network_avoid_bad_wifi=0" "$(cat "$LOG/adb.log")"
grep -q 'settings put global wifi_always_requested 1' "$LOG/adb.log" \
  && ok "writes wifi_always_requested=1" || bad "writes wifi_always_requested=1" "$(cat "$LOG/adb.log")"
[ "$(cat "$LOG/avoid")" = 0 ] && [ "$(cat "$LOG/always")" = 1 ] \
  && ok "both values are read back" || bad "both values are read back" "$(cat "$LOG/avoid" "$LOG/always")"
grep -q 'network_avoid_bad_wifi: 0 (recommended)' "$LOG/out" \
  && ok "reports the applied value" || bad "reports the applied value" "$(cat "$LOG/out")"

# 4. Applying again is harmless and leaves the recommended values in place.
if run; then ok "a second apply exits 0"; else bad "a second apply exits 0" "$(cat "$LOG/out")"; fi
[ "$(cat "$LOG/avoid")" = 0 ] && [ "$(cat "$LOG/always")" = 1 ] \
  && ok "the second apply is idempotent" || bad "the second apply is idempotent" "$(cat "$LOG/avoid" "$LOG/always")"

# 5. No phone is a clear failure and makes no setting.
fresh
printf 'List of devices attached\n' >"$LOG/devices"
if run; then bad "no phone exits 1"; else ok "no phone exits 1"; fi
grep -q 'no phone attached' "$LOG/out" && ok "explains the missing phone" \
  || bad "explains the missing phone" "$(cat "$LOG/out")"
grep -q ' settings put ' "$LOG/adb.log" && bad "no phone writes nothing" \
  || ok "no phone writes nothing"

# 6. --help and unknown arguments.
fresh
if run --help; then ok "--help exits 0"; else bad "--help exits 0"; fi
if run --bogus; then bad "unknown argument exits 1"; else ok "unknown argument exits 1"; fi

finish
