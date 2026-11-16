#!/usr/bin/env bash
# Hermetic tests for bin/phone-proxy-start: stub adb with the app's service
# dump and its intents. No phone, no screen, no keyguard.
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

# The app as adb sees it: a start makes it listen (unless its SSID gate says
# otherwise), a stop takes the service away, and the dump is what it says.
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
      *action.START*)
        if [ -f "$LOG/gated" ]; then
          printf '  state       "laptop" not listening: on another network\n' >"$LOG/dump"
        else
          printf '  state       "laptop" listening on 0.0.0.0:1081 · 0 clients\n' >"$LOG/dump"
        fi
        ;;
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
  : >"$LOG/dump"
  : >"$LOG/actions"
  rm -f "$LOG/gated"
}

# 1. --check says it is stopped, and changes nothing.
fresh
if run --check; then bad "--check on a stopped proxy exits 1"; else ok "--check on a stopped proxy exits 1"; fi
grep -q 'proxy is not listening (stopped)' "$LOG/out" && ok "says it is not listening" \
  || bad "says it is not listening" "$(cat "$LOG/out")"
[ -s "$LOG/actions" ] && bad "--check sends nothing" || ok "--check sends nothing"

# 2. --check on a listening proxy is 0.
fresh
printf '  state       "laptop" listening on 0.0.0.0:1081 · 2 clients\n' >"$LOG/dump"
if run --check; then ok "--check on a listening proxy exits 0"; else bad "--check on a listening proxy exits 0" "$(cat "$LOG/out")"; fi
grep -q 'already listening ("laptop" listening on 0.0.0.0:1081' "$LOG/out" \
  && ok "quotes what the service says" || bad "quotes what the service says" "$(cat "$LOG/out")"

# 3. A start is the app's own intent, naming the service by its component.
fresh
if run; then ok "start exits 0"; else bad "start exits 0" "$(cat "$LOG/out")"; fi
grep -q 'am start-foreground-service -n org.phonelink.proxy/org.phonelink.proxy.ProxyService -a org.phonelink.proxy.action.START$' \
  "$LOG/actions" && ok "sends START to the app's service" || bad "sends START to the app's service" "$(cat "$LOG/actions")"
grep -q 'proxy started ("laptop" listening' "$LOG/out" && ok "says it started" \
  || bad "says it started" "$(cat "$LOG/out")"

# 4. Starting something already listening sends nothing.
fresh
printf '  state       "laptop" listening on 0.0.0.0:1081 · 0 clients\n' >"$LOG/dump"
if run; then ok "starting a running proxy exits 0"; else bad "starting a running proxy exits 0" "$(cat "$LOG/out")"; fi
[ -s "$LOG/actions" ] && bad "a running proxy is not restarted" || ok "a running proxy is not restarted"

# 5. A gate that says "another network" is the reason, not a mystery.
fresh
: >"$LOG/gated"
if run; then bad "a gated start exits 1"; else ok "a gated start exits 1"; fi
grep -q 'SSID gate does not match' "$LOG/out" && ok "names the SSID gate" \
  || bad "names the SSID gate" "$(cat "$LOG/out")"

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
