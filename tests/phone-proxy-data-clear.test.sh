#!/usr/bin/env bash
# Hermetic tests for bin/phone-proxy-data-clear: stub adb, no phone.
set -u

BASH_BIN=$(command -v bash)
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/bin/phone-proxy-data-clear
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
  devices) printf 'List of devices attached\nXPLO2EEA0001541\tdevice\n' ;;
  shell)
    args=("${args[@]:1}")
    case "${args[0]:-} ${args[1]:-}" in
      "pm path")
        [ -f "$LOG/installed" ] && printf 'package:/data/app/x/base.apk\n'
        ;;
      "pm clear")
        printf 'pm clear %s\n' "${args[2]:-}" >>"$LOG/clear.log"
        if [ -f "$LOG/installed" ]; then
          printf 'Success\n'
          rm -f "$LOG/data"
        else
          printf 'Failed\n'
        fi
        ;;
      "ip -4") printf '2: wlan0    inet 10.244.108.165/24 brd 10.244.108.255 scope global wlan0\n' ;;
      *) : ;;
    esac
    ;;
esac
EOF
sed -i "1s|.*|#!$BASH_BIN|" "$STUBS/adb"

# Nothing accepts connections once the data is cleared.
cat >"$STUBS/timeout" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
sed -i "1s|.*|#!$BASH_BIN|" "$STUBS/timeout"
chmod +x "$STUBS/adb" "$STUBS/timeout"
export PATH="$STUBS:$PATH"

run() {
  "$BASH_BIN" "$SCRIPT" "$@" >"$LOG/out" 2>&1
}

# 1. Not installed: nothing to do.
rm -f "$LOG/installed" "$LOG/clear.log"
if run --yes; then
  ok "not installed exits 0"
else
  bad "not installed exits 0" "$(cat "$LOG/out")"
fi
grep -q 'not installed' "$LOG/out" && ok "not installed is reported" \
  || bad "not installed is reported"
[ ! -f "$LOG/clear.log" ] && ok "not installed runs no pm clear" || bad "not installed runs no pm clear"

# 2. --check previews and leaves the data alone.
touch "$LOG/installed" "$LOG/data"
rm -f "$LOG/clear.log"
if run --check; then
  ok "--check exits 0"
else
  bad "--check exits 0" "$(cat "$LOG/out")"
fi
grep -q 'would run: adb -s XPLO2EEA0001541 shell pm clear com.tokyoxpa3.androidproxy' "$LOG/out" \
  && ok "--check shows the exact command" || bad "--check shows the exact command" "$(cat "$LOG/out")"
[ ! -f "$LOG/clear.log" ] && ok "--check clears nothing" || bad "--check clears nothing"
[ -f "$LOG/data" ] && ok "--check keeps the data" || bad "--check keeps the data"

# 3. Without a terminal and without --yes it refuses.
if run </dev/null; then
  bad "non-interactive without --yes exits 1"
else
  ok "non-interactive without --yes exits 1"
fi
grep -q 'refusing to clear data without --yes' "$LOG/out" \
  && ok "refusal explains --yes" || bad "refusal explains --yes" "$(cat "$LOG/out")"
[ ! -f "$LOG/clear.log" ] && ok "refusal clears nothing" || bad "refusal clears nothing"

# 4. --yes clears and reports it.
if run --yes; then
  ok "--yes exits 0"
else
  bad "--yes exits 0" "$(cat "$LOG/out")"
fi
grep -q 'pm clear com.tokyoxpa3.androidproxy' "$LOG/clear.log" \
  && ok "--yes runs pm clear for the pinned serial" || bad "--yes runs pm clear for the pinned serial"
grep -q 'cleared com.tokyoxpa3.androidproxy data' "$LOG/out" \
  && ok "clearing is reported" || bad "clearing is reported" "$(cat "$LOG/out")"
grep -q 'tunnel stops within 5 s' "$LOG/out" && ok "tunnel side effect is stated" \
  || bad "tunnel side effect is stated"

# 5. Clearing again is harmless.
if run --yes; then
  ok "second clear exits 0"
else
  bad "second clear exits 0" "$(cat "$LOG/out")"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
