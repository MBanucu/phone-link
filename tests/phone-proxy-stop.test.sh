#!/usr/bin/env bash
# Hermetic tests for bin/phone-proxy-stop: stub adb with the app's service
# dump and its intents. No phone, no screen, no keyguard.
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
cmd="${args[*]}"
case $cmd in
  "devices") printf 'List of devices attached\nXPLO2EEA0001541\tdevice\n' ;;
  "shell pm path "*) cat "$LOG/pm" ;;
  "shell dumpsys activity service "*) cat "$LOG/dump" ;;
  "shell am start-foreground-service "*)
    printf '%s\n' "$cmd" >>"$LOG/actions"
    case $cmd in
      *action.STOP*) : >"$LOG/dump" ;;
      *action.START*) printf '  state       "laptop" listening on 0.0.0.0:1081 · 0 clients\n' >"$LOG/dump" ;;
    esac
    ;;
esac
EOF
sed -i "1s|.*|#!$BASH_BIN|" "$STUBS/adb"
chmod +x "$STUBS"/*
export PATH="$STUBS:$PATH"

run() {
  "$BASH_BIN" "$SCRIPT" "$@" >"$LOG/out" 2>&1
}

fresh() {
  printf 'package:/data/app/base.apk\n' >"$LOG/pm"
  printf '  state       "laptop" listening on 0.0.0.0:1081 · 1 client\n' >"$LOG/dump"
  : >"$LOG/actions"
}

# 1. --check on a running proxy is 1, and says what it sees.
fresh
if run --check; then bad "--check on a running proxy exits 1"; else ok "--check on a running proxy exits 1"; fi
grep -q 'proxy is running ("laptop" listening on 0.0.0.0:1081' "$LOG/out" \
  && ok "quotes what the service says" || bad "quotes what the service says" "$(cat "$LOG/out")"
[ -s "$LOG/actions" ] && bad "--check sends nothing" || ok "--check sends nothing"

# 2. --check on a stopped proxy is 0.
fresh
: >"$LOG/dump"
if run --check; then ok "--check on a stopped proxy exits 0"; else bad "--check on a stopped proxy exits 0" "$(cat "$LOG/out")"; fi
grep -q 'proxy is not running' "$LOG/out" && ok "says it is not running" \
  || bad "says it is not running" "$(cat "$LOG/out")"

# 3. A stop is the app's own intent, naming the service by its component.
fresh
if run; then ok "stop exits 0"; else bad "stop exits 0" "$(cat "$LOG/out")"; fi
grep -q 'am start-foreground-service -n org.phonelink.proxy/org.phonelink.proxy.ProxyService -a org.phonelink.proxy.action.STOP$' \
  "$LOG/actions" && ok "sends STOP to the app's service" || bad "sends STOP to the app's service" "$(cat "$LOG/actions")"
grep -q 'proxy stopped' "$LOG/out" && ok "says it stopped" || bad "says it stopped" "$(cat "$LOG/out")"

# 4. Stopping something that is not running sends nothing.
fresh
: >"$LOG/dump"
if run; then ok "stopping a stopped proxy exits 0"; else bad "stopping a stopped proxy exits 0" "$(cat "$LOG/out")"; fi
[ -s "$LOG/actions" ] && bad "a stopped proxy gets no intent" || ok "a stopped proxy gets no intent"

# 5. A proxy the app keeps running is a failure, not a silent success.
fresh
cat >"$STUBS/adb" <<'EOF'
#!/usr/bin/env bash
args=("$@")
if [ "${args[0]:-}" = "-s" ]; then args=("${args[@]:2}"); fi
cmd="${args[*]}"
case $cmd in
  "devices") printf 'List of devices attached\nXPLO2EEA0001541\tdevice\n' ;;
  "shell pm path "*) cat "$LOG/pm" ;;
  "shell dumpsys activity service "*) cat "$LOG/dump" ;;
  "shell am start-foreground-service "*) printf '%s\n' "$cmd" >>"$LOG/actions" ;;
esac
EOF
sed -i "1s|.*|#!$BASH_BIN|" "$STUBS/adb"
chmod +x "$STUBS/adb"
if run; then bad "a proxy that keeps listening exits 1"; else ok "a proxy that keeps listening exits 1"; fi
grep -q 'proxy did not stop' "$LOG/out" && ok "says it did not stop" \
  || bad "says it did not stop" "$(cat "$LOG/out")"

# 6. An app that is not installed is said plainly.
fresh
: >"$LOG/pm"
if run; then bad "a missing app exits 1"; else ok "a missing app exits 1"; fi
grep -q 'org.phonelink.proxy is not installed; run phone-proxy-install first' "$LOG/out" \
  && ok "says which app and how to install it" || bad "says which app and how to install it" "$(cat "$LOG/out")"

# 7. --help and unknown arguments.
fresh
if run --help; then ok "--help exits 0"; else bad "--help exits 0"; fi
if run --bogus; then bad "unknown argument exits 1"; else ok "unknown argument exits 1"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
