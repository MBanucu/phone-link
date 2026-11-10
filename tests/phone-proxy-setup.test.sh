#!/usr/bin/env bash
# Hermetic tests for bin/phone-proxy-setup: stub adb serving a settings-screen
# XML, stub unlock/timeout/curl. No phone, no network.
set -u

BASH_BIN=$(command -v bash)
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/bin/phone-proxy-setup
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export LOG=$TMP/log STUBS=$TMP/bin HOME=$TMP PHONE_SECRETS=$TMP/secrets
mkdir -p "$LOG" "$STUBS"
printf 'PHONE_SOCKS_PASS=secret123\n' >"$PHONE_SECRETS"

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

# The settings screen: port, username, password (masked), auto-start checkbox,
# Start/Stop button, all as the app builds them.
cat >"$STUBS/adb" <<'EOF'
#!/usr/bin/env bash
args=("$@")
if [ "${args[0]:-}" = "-s" ]; then args=("${args[@]:2}"); fi
render_xml() {
  local port user pass auto btn bullets
  port=$(cat "$LOG/port")
  user=$(cat "$LOG/user")
  pass=$(cat "$LOG/pass" 2>/dev/null || true)
  auto=$(cat "$LOG/auto")
  if [ -f "$LOG/running" ]; then btn='🛑 Stop Proxy Service'; else btn='🚀 Start 5G Proxy'; fi
  bullets=''
  if [ -n "$pass" ]; then bullets=$(printf '•%.0s' $(seq 1 ${#pass})); fi
  cat <<XML
<?xml version='1.0' encoding='UTF-8' standalone='yes' ?>
<hierarchy rotation="0">
 <node package="com.tokyoxpa3.androidproxy" class="android.widget.EditText" text="$port" bounds="[400,800][1400,1000]" />
 <node package="com.tokyoxpa3.androidproxy" class="android.widget.EditText" text="$user" bounds="[400,1000][1400,1200]" />
 <node package="com.tokyoxpa3.androidproxy" class="android.widget.EditText" text="$bullets" bounds="[400,1200][1400,1400]" />
 <node package="com.tokyoxpa3.androidproxy" class="android.widget.CheckBox" text="Start the proxy automatically after a reboot" checked="$auto" bounds="[48,1400][1392,1560]" />
 <node package="com.tokyoxpa3.androidproxy" class="android.widget.Button" text="$btn" bounds="[48,1600][1392,1800]" />
 <node package="com.tokyoxpa3.androidproxy" class="android.widget.TextView" text="✅ 5G Proxy Running" bounds="[80,1820][1360,1900]" />
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
      dumpsys) printf '  showing=false\n' ;;
      monkey) printf 'Events injected: 1\n' ;;
      wm) printf 'Physical size: 1440x3200\n' ;;
      ip*) printf '2: wlan0    inet 10.244.108.165/24 brd 10.244.108.255 scope global wlan0\n' ;;
      uiautomator) render_xml >"$LOG/remote.xml" ;;
      input)
        args=("${args[@]:1}")
        case "${args[0]:-}" in
          tap)
            printf 'tap %s %s\n' "${args[1]}" "${args[2]}" >>"$LOG/input.log"
            case ${args[2]:-} in
              900) printf 'port\n' >"$LOG/current" ;;
              1100) printf 'user\n' >"$LOG/current" ;;
              1300) printf 'pass\n' >"$LOG/current" ;;
              1480)
                if [ "$(cat "$LOG/auto")" = true ]; then printf 'false\n' >"$LOG/auto"; else printf 'true\n' >"$LOG/auto"; fi
                ;;
              1700)
                if [ -f "$LOG/running" ]; then rm -f "$LOG/running"; else : >"$LOG/running"; fi
                ;;
            esac
            ;;
          keyevent) printf 'keyevent %s\n' "${args[*]:1}" >>"$LOG/input.log" ;;
          text)
            printf 'text %s\n' "${args[1]:-}" >>"$LOG/input.log"
            case "$(cat "$LOG/current" 2>/dev/null)" in
              port) printf '%s\n' "${args[1]:-}" >"$LOG/port" ;;
              user) printf '%s\n' "${args[1]:-}" >"$LOG/user" ;;
              pass) printf '%s' "${args[1]:-}" >"$LOG/pass" ;;
            esac
            ;;
          swipe) printf 'swipe %s\n' "${args[*]:1}" >>"$LOG/input.log" ;;
        esac
        ;;
      *) : ;;
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

# The phone answers while the proxy is running.
cat >"$STUBS/timeout" <<'EOF'
#!/usr/bin/env bash
# The script bounds `adb shell uiautomator dump` with `timeout 20`; run it.
if [ "${1:-}" = "20" ]; then shift; exec "$@"; fi
[ -f "$LOG/running" ]
EOF
sed -i "1s|.*|#!$BASH_BIN|" "$STUBS/timeout"

cat >"$STUBS/curl" <<'EOF'
#!/usr/bin/env bash
printf '200'
EOF
sed -i "1s|.*|#!$BASH_BIN|" "$STUBS/curl"
chmod +x "$STUBS/adb" "$STUBS/phone-unlock" "$STUBS/timeout" "$STUBS/curl"
export PATH="$STUBS:$PATH"

fresh_state() {
  printf '1080\n' >"$LOG/port"
  : >"$LOG/user"
  : >"$LOG/pass"
  printf 'false\n' >"$LOG/auto"
  rm -f "$LOG/running" "$LOG/current" "$LOG/input.log"
}

run() {
  "$BASH_BIN" "$SCRIPT" "$@" >"$LOG/out" 2>&1
}

# 1. --check reports the mismatches and touches nothing.
fresh_state
if run --check; then
  bad "--check exits 1 when unconfigured"
else
  ok "--check exits 1 when unconfigured"
fi
grep -q 'port       1080 (want 1080)' "$LOG/out" && ok "--check reports the port" \
  || bad "--check reports the port" "$(cat "$LOG/out")"
grep -q 'username   <empty> (want proxy)' "$LOG/out" && ok "--check reports the empty username" \
  || bad "--check reports the empty username" "$(cat "$LOG/out")"
grep -q 'password   0 chars (want 9)' "$LOG/out" && ok "--check counts the password" \
  || bad "--check counts the password" "$(cat "$LOG/out")"
grep -q 'auto-start false (want true)' "$LOG/out" && ok "--check reports auto-start" \
  || bad "--check reports auto-start" "$(cat "$LOG/out")"
[ ! -f "$LOG/input.log" ] && ok "--check taps nothing" || bad "--check taps nothing"

# 2. A full run writes every field, enables auto-start and starts the proxy.
if run; then
  ok "setup exits 0"
else
  bad "setup exits 0" "$(cat "$LOG/out")"
fi
for want in 'tap 900 900' 'text 1080' 'tap 900 1100' 'text proxy' 'tap 900 1300' 'text secret123' 'tap 720 1480' 'tap 720 1700'; do
  grep -qF "$want" "$LOG/input.log" && ok "input sequence has: $want" \
    || bad "input sequence has: $want" "$(cat "$LOG/input.log")"
done
grep -q 'keyevent KEYCODE_MOVE_END 67 67' "$LOG/input.log" \
  && ok "fields are cleared before typing" || bad "fields are cleared before typing"
[ "$(cat "$LOG/port")" = 1080 ] && ok "port written" || bad "port written"
[ "$(cat "$LOG/user")" = proxy ] && ok "username written" || bad "username written"
[ "$(cat "$LOG/pass")" = secret123 ] && ok "password written" || bad "password written" "$(cat "$LOG/pass")"
[ "$(cat "$LOG/auto")" = true ] && ok "auto-start enabled" || bad "auto-start enabled"
[ -f "$LOG/running" ] && ok "proxy started" || bad "proxy started"
grep -q 'phone proxy configured and verified' "$LOG/out" && ok "verified through the proxy" \
  || bad "verified through the proxy" "$(cat "$LOG/out")"

# 3. --check now matches.
if run --check; then
  ok "--check exits 0 when configured"
else
  bad "--check exits 0 when configured" "$(cat "$LOG/out")"
fi

# 4. --no-auto-start turns the checkbox off without restarting the proxy.
rm -f "$LOG/input.log"
if run --no-auto-start; then
  ok "--no-auto-start exits 0"
else
  bad "--no-auto-start exits 0" "$(cat "$LOG/out")"
fi
grep -q 'tap 720 1480' "$LOG/input.log" && ok "--no-auto-start toggles the checkbox" \
  || bad "--no-auto-start toggles the checkbox"
[ "$(cat "$LOG/auto")" = false ] && ok "auto-start disabled" || bad "auto-start disabled"
if grep -q 'tap 720 1700' "$LOG/input.log"; then
  bad "--no-auto-start leaves the running proxy alone"
else
  ok "--no-auto-start leaves the running proxy alone"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
