#!/usr/bin/env bash
# Hermetic tests for bin/phone-proxy-stop: stub adb serving the app screen,
# stub phone-unlock and timeout. No phone, no network.
set -u

BASH_BIN=$(command -v bash)
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/bin/phone-proxy-stop
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
render_xml() {
  local btn status
  if [ -f "$LOG/running" ]; then
    btn='🛑 Stop Proxy Service'
    status='✅ 5G Proxy Running'
  else
    btn='🚀 Start 5G Proxy'
    status='Proxy Stopped'
  fi
  cat <<XML
<?xml version='1.0' encoding='UTF-8' standalone='yes' ?>
<hierarchy rotation="0">
 <node package="com.tokyoxpa3.androidproxy" class="android.widget.Button" text="$btn" bounds="[48,1600][1392,1800]" />
 <node package="com.tokyoxpa3.androidproxy" class="android.widget.TextView" text="$status" bounds="[80,1820][1360,1900]" />
</hierarchy>
XML
}
case "${args[0]:-}" in
  devices) printf 'List of devices attached\nXPLO2EEA0001541\tdevice\n' ;;
  pull) cp "$LOG/remote.xml" "${args[2]:-}" ;;
  shell)
    args=("${args[@]:1}")
    case "${args[0]:-}" in
      pm) [ "${args[1]:-}" = path ] && printf 'package:/data/app/x/base.apk\n' ;;
      dumpsys) printf '  showing=%s\n' "$(cat "$LOG/keyguard" 2>/dev/null || echo false)" ;;
      monkey) printf 'Events injected: 1\n' ;;
      uiautomator) render_xml >"$LOG/remote.xml" ;;
      input)
        args=("${args[@]:1}")
        case "${args[0]:-}" in
          tap)
            printf 'tap %s %s\n' "${args[1]}" "${args[2]}" >>"$LOG/input.log"
            if [ "${args[2]:-}" = 1700 ] && [ -f "$LOG/running" ]; then rm -f "$LOG/running"; fi
            ;;
          keyevent) printf 'keyevent %s\n' "${args[*]:1}" >>"$LOG/input.log" ;;
        esac
        ;;
    esac
    ;;
esac
EOF
sed -i "1s|.*|#!$BASH_BIN|" "$STUBS/adb"

cat >"$STUBS/phone-unlock" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
sed -i "1s|.*|#!$BASH_BIN|" "$STUBS/phone-unlock"

cat >"$STUBS/timeout" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "20" ]; then shift; exec "$@"; fi
exit 0
EOF
sed -i "1s|.*|#!$BASH_BIN|" "$STUBS/timeout"

chmod +x "$STUBS/adb" "$STUBS/phone-unlock" "$STUBS/timeout"
export PATH="$STUBS:$PATH"

fresh_state() {
  printf 'false\n' >"$LOG/keyguard"
  rm -f "$LOG/running" "$LOG/input.log"
}

run() {
  "$BASH_BIN" "$SCRIPT" "$@" >"$LOG/out" 2>&1
}

# 1. --check on a locked phone fails fast, read-only.
fresh_state
: >"$LOG/running"
printf 'true\n' >"$LOG/keyguard"
if run --check; then
  bad "--check fails on a locked phone"
else
  ok "--check fails on a locked phone"
fi
grep -q 'phone is locked; run phone-unlock' "$LOG/out" && ok "locked message names phone-unlock" \
  || bad "locked message names phone-unlock" "$(cat "$LOG/out")"
[ ! -f "$LOG/input.log" ] && ok "locked --check taps nothing" || bad "locked --check taps nothing"

# 2. --check on a stopped proxy exits 0 and taps nothing.
fresh_state
if run --check; then
  ok "--check exits 0 when stopped"
else
  bad "--check exits 0 when stopped" "$(cat "$LOG/out")"
fi
grep -q 'proxy is not running' "$LOG/out" && ok "--check says it is not running" \
  || bad "--check says it is not running" "$(cat "$LOG/out")"
[ ! -f "$LOG/input.log" ] && ok "--check taps nothing when stopped" || bad "--check taps nothing when stopped"

# 3. --check reports a running proxy and exits 1.
: >"$LOG/running"
if run --check; then
  bad "--check exits 1 when running"
else
  ok "--check exits 1 when running"
fi
grep -q 'proxy is running' "$LOG/out" && ok "--check says it is running" \
  || bad "--check says it is running" "$(cat "$LOG/out")"
[ ! -f "$LOG/input.log" ] && ok "--check taps nothing when running" || bad "--check taps nothing when running"

# 4. A running proxy is stopped with one tap.
if run; then
  ok "stop exits 0"
else
  bad "stop exits 0" "$(cat "$LOG/out")"
fi
grep -q 'tap 720 1700' "$LOG/input.log" && ok "stop taps the Stop button" \
  || bad "stop taps the Stop button" "$(cat "$LOG/input.log" 2>/dev/null)"
[ ! -f "$LOG/running" ] && ok "proxy is stopped afterwards" || bad "proxy is stopped afterwards"
grep -q 'proxy stopped' "$LOG/out" && ok "stop reports success" \
  || bad "stop reports success" "$(cat "$LOG/out")"

# 5. Stopping a stopped proxy taps nothing.
if run; then
  ok "second stop exits 0"
else
  bad "second stop exits 0" "$(cat "$LOG/out")"
fi
grep -q 'proxy is not running' "$LOG/out" && ok "second stop says not running" \
  || bad "second stop says not running" "$(cat "$LOG/out")"
[ "$(grep -c 'tap ' "$LOG/input.log")" = 1 ] && ok "second stop taps nothing" \
  || bad "second stop taps nothing" "$(cat "$LOG/input.log")"

# 6. --help exits 0.
if run --help; then ok "--help exits 0"; else bad "--help exits 0"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
