#!/usr/bin/env bash
# Hermetic tests for bin/phone-proxy-battery-whitelist: stub adb, no phone.
set -u

BASH_BIN=$(command -v bash)
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/bin/phone-proxy-battery-whitelist
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
      "pm path") [ -f "$LOG/installed" ] && printf 'package:/data/app/x/base.apk\n' ;;
      "dumpsys deviceidle")
        if [ -f "$LOG/whitelisted" ]; then
          printf 'user,com.tokyoxpa3.androidproxy,10300\n'
        else
          printf 'user,com.example.other,10100\n'
        fi
        ;;
      "cmd deviceidle")
        printf '%s\n' "${args[*]:1}" >>"$LOG/whitelist.log"
        : >"$LOG/whitelisted"
        printf 'Added: com.tokyoxpa3.androidproxy\n'
        ;;
      *) : ;;
    esac
    ;;
esac
EOF
sed -i "1s|.*|#!$BASH_BIN|" "$STUBS/adb"
chmod +x "$STUBS/adb"
export PATH="$STUBS:$PATH"

run() {
  "$BASH_BIN" "$SCRIPT" "$@" >"$LOG/out" 2>&1
}

# 1. --check on a phone that is not whitelisted is read-only and fails.
touch "$LOG/installed"
rm -f "$LOG/whitelisted" "$LOG/whitelist.log"
if run --check; then
  bad "--check exits 1 when not whitelisted"
else
  ok "--check exits 1 when not whitelisted"
fi
grep -q 'not whitelisted' "$LOG/out" && ok "--check says it is not whitelisted" \
  || bad "--check says it is not whitelisted" "$(cat "$LOG/out")"
[ ! -f "$LOG/whitelist.log" ] && ok "--check changes nothing" || bad "--check changes nothing"

# 2. Adding whitelists the app.
if run; then
  ok "add exits 0"
else
  bad "add exits 0" "$(cat "$LOG/out")"
fi
grep -qF 'deviceidle whitelist +com.tokyoxpa3.androidproxy' "$LOG/whitelist.log" \
  && ok "exact cmd deviceidle argv" || bad "exact cmd deviceidle argv" "$(cat "$LOG/whitelist.log" 2>/dev/null)"
[ -f "$LOG/whitelisted" ] && ok "app is whitelisted afterwards" || bad "app is whitelisted afterwards"
grep -q 'Doze will now leave' "$LOG/out" && ok "effect is explained" || bad "effect is explained"

# 3. A second run is a no-op.
rm -f "$LOG/whitelist.log"
if run; then
  ok "second run exits 0"
else
  bad "second run exits 0" "$(cat "$LOG/out")"
fi
grep -q 'already' "$LOG/out" && ok "second run reports already whitelisted" \
  || bad "second run reports already whitelisted" "$(cat "$LOG/out")"
[ ! -f "$LOG/whitelist.log" ] && ok "second run runs no command" || bad "second run runs no command"

# 4. --check now passes.
if run --check; then
  ok "--check exits 0 when whitelisted"
else
  bad "--check exits 0 when whitelisted" "$(cat "$LOG/out")"
fi

# 5. Not installed is refused.
rm -f "$LOG/installed" "$LOG/whitelisted"
if run; then
  bad "not installed exits 1"
else
  ok "not installed exits 1"
fi
grep -q 'phone-proxy-install' "$LOG/out" && ok "not installed points at the installer" \
  || bad "not installed points at the installer" "$(cat "$LOG/out")"

# 6. --help works without a phone.
if "$BASH_BIN" "$SCRIPT" --help >"$LOG/out" 2>&1; then
  ok "--help exits 0"
else
  bad "--help exits 0"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
