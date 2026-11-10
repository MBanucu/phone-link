#!/usr/bin/env bash
# Hermetic tests for bin/phone-proxy-start: stub adb serving the app screen,
# stub phone-unlock and timeout. No phone, no network.
set -u

BASH_BIN=$(command -v bash)
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/bin/phone-proxy-start
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

# The app screen with just what these scripts read: the Start/Stop button and
# the status line.
cat >"$STUBS/adb" <<'EOF'
#!/usr/bin/env bash
args=("$@")
if [ "${args[0]:-}" = "-s" ]; then args=("${args[@]:2}"); fi
render_xml() {
  local btn status
  if [ -f "$LOG/failed" ]; then
    btn='🚀 Start 5G Proxy'
    status='❌ Proxy Failed to Start: test'
  elif [ -f "$LOG/running" ]; then
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
            if [ "${args[2]:-}" = 1700 ]; then
              if [ -f "$LOG/fail" ]; then
                : >"$LOG/failed"
              elif [ -f "$LOG/running" ]; then
                rm -f "$LOG/running"
              else
                : >"$LOG/running"
              fi
            fi
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

# The script bounds `adb shell uiautomator dump` with `timeout 20`; run it.
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
  rm -f "$LOG/running" "$LOG/failed" "$LOG/fail" "$LOG/input.log"
}

run() {
  "$BASH_BIN" "$SCRIPT" "$@" >"$LOG/out" 2>&1
}

# 1. --check on a locked phone fails fast, read-only.
fresh_state
printf 'true\n' >"$LOG/keyguard"
if run --check; then
  bad "--check fails on a locked phone"
else
  ok "--check fails on a locked phone"
fi
grep -q 'phone is locked; run phone-unlock' "$LOG/out" && ok "locked message names phone-unlock" \
  || bad "locked message names phone-unlock" "$(cat "$LOG/out")"
[ ! -f "$LOG/input.log" ] && ok "locked --check taps nothing" || bad "locked --check taps nothing"

# 2. --check reports a stopped proxy and exits 1.
fresh_state
if run --check; then
  bad "--check exits 1 when stopped"
else
  ok "--check exits 1 when stopped"
fi
grep -q 'proxy is stopped' "$LOG/out" && ok "--check says it is stopped" \
  || bad "--check says it is stopped" "$(cat "$LOG/out")"
[ ! -f "$LOG/input.log" ] && ok "--check taps nothing when stopped" || bad "--check taps nothing when stopped"

# 3. --check exits 0 and taps nothing when already running.
: >"$LOG/running"
if run --check; then
  ok "--check exits 0 when running"
else
  bad "--check exits 0 when running" "$(cat "$LOG/out")"
fi
grep -q 'proxy is already running' "$LOG/out" && ok "--check says it is running" \
  || bad "--check says it is running" "$(cat "$LOG/out")"
[ ! -f "$LOG/input.log" ] && ok "--check taps nothing when running" || bad "--check taps nothing when running"

# 4. A stopped proxy is started with one tap.
fresh_state
if run; then
  ok "start exits 0"
else
  bad "start exits 0" "$(cat "$LOG/out")"
fi
grep -q 'tap 720 1700' "$LOG/input.log" && ok "start taps the Start button" \
  || bad "start taps the Start button" "$(cat "$LOG/input.log" 2>/dev/null)"
[ -f "$LOG/running" ] && ok "proxy is running afterwards" || bad "proxy is running afterwards"
grep -q 'proxy started' "$LOG/out" && ok "start reports success" \
  || bad "start reports success" "$(cat "$LOG/out")"

# 5. Starting an already running proxy taps nothing.
if run; then
  ok "second start exits 0"
else
  bad "second start exits 0" "$(cat "$LOG/out")"
fi
grep -q 'proxy is already running' "$LOG/out" && ok "second start says already running" \
  || bad "second start says already running" "$(cat "$LOG/out")"
[ "$(grep -c 'tap ' "$LOG/input.log")" = 1 ] && ok "second start taps nothing" \
  || bad "second start taps nothing" "$(cat "$LOG/input.log")"

# 6. A failed start is reported instead of waiting forever.
fresh_state
: >"$LOG/fail"
if run; then
  bad "failed start exits 1"
else
  ok "failed start exits 1"
fi
grep -q 'proxy failed to start' "$LOG/out" && ok "failed start explains the status" \
  || bad "failed start explains the status" "$(cat "$LOG/out")"
[ ! -f "$LOG/running" ] && ok "failed start leaves the proxy stopped" || bad "failed start leaves the proxy stopped"

# 7. --help exits 0.
if run --help; then ok "--help exits 0"; else bad "--help exits 0"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
