#!/usr/bin/env bash
# Hermetic tests for bin/phone-proxy-switch: a stub adb whose dump is the app's
# `running`/`saved` lines and whose START/STOP write them, a stub curl for the
# request through the new port, and a stub systemctl for what was running.
# No phone, no root, no network, no /run.
set -u

BASH_BIN=$(command -v bash)
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/bin/phone-proxy-switch
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

# The app: a START adds a `running` line for its port (a profile's own port when
# --es profile is given), a STOP removes one, and every intent is logged so the
# order is testable. $LOG/start_fails keeps the dump unchanged, the way a proxy
# whose SSID gate is closed never binds.
cat >"$STUBS/adb" <<'EOF'
#!/usr/bin/env bash
args=("$@")
if [ "${args[0]:-}" = "-s" ]; then args=("${args[@]:2}"); fi
cmd="${args[*]}"
case $cmd in
  "devices") cat "$LOG/devices" ;;
  "shell pm path "*) cat "$LOG/pm" ;;
  "shell dumpsys activity service "*) cat "$LOG/dump" ;;
  "shell ip -4 -o addr show 2>/dev/null"*) cat "$LOG/ips" ;;
  "shell am start-foreground-service "*)
    printf '%s\n' "$cmd" >>"$LOG/actions"
    port=$(sed -n 's/.*--ei port \([0-9][0-9]*\).*/\1/p' <<<"$cmd")
    if [[ $cmd == *"action.START"* ]]; then
      if [[ $cmd == *"--es profile "* ]]; then
        name=$(sed -n 's/.*--es profile \([^ ]*\).*/\1/p' <<<"$cmd")
        port=$(cat "$LOG/saved-$name" 2>/dev/null)
      fi
      [ -f "$LOG/start_fails" ] && exit 0
      [ -n "$port" ] && printf '  running     port %s · 0 clients\n' "$port" >>"$LOG/dump"
    elif [[ $cmd == *"action.STOP"* ]]; then
      if [ -z "$port" ]; then
        : >"$LOG/dump"
      else
        grep -v -e "port $port ·" "$LOG/dump" >"$LOG/dump.new" || true
        mv "$LOG/dump.new" "$LOG/dump"
      fi
    fi
    ;;
esac
EOF

cat >"$STUBS/curl" <<'EOF'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >>"$LOG/actions"
printf '%s' "$(cat "$LOG/code")"
EOF

cat >"$STUBS/systemctl" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  is-active)
    case "${2:-}" in
      phone-tun.service) cat "$LOG/tun" ;;
      phone-socks-relay.service) cat "$LOG/relay" ;;
      *) printf 'inactive\n' ;;
    esac
    ;;
  restart) printf 'systemctl restart %s\n' "${2:-}" >>"$LOG/actions" ;;
esac
EOF

cat >"$STUBS/id" <<'EOF'
#!/usr/bin/env bash
printf '0\n'
EOF

cat >"$STUBS/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF

sed -i "1s|.*|#!$BASH_BIN|" "$STUBS"/*
chmod +x "$STUBS"/*
export PATH="$STUBS:$PATH"

export PHONE_SECRETS=$TMP/secrets
export PHONE_RUNTIME_PORT_FILE=$TMP/run/proxy-port
# A stub answers in the dump it just wrote; there is nothing to wait out.
export PHONE_PROXY_WAIT=0 PHONE_PROXY_SETTLE=0
printf 'PHONE_SOCKS_PASS=s3cret\n' >"$PHONE_SECRETS"

run() {
  "$BASH_BIN" "$SCRIPT" "$@" >"$LOG/out" 2>&1
}

runtime_port() {
  cat "$PHONE_RUNTIME_PORT_FILE" 2>/dev/null
}

# A phone listening on 1080 (in use), with three saved proxies: one on 1080,
# one on 2000 that is not running, and one whose user the laptop has no
# password for.
fresh() {
  printf 'List of devices attached\nXPLO2EEA0001541\tdevice\n' >"$LOG/devices"
  printf 'package:/data/app/base.apk\n' >"$LOG/pm"
  printf '2: wlan0    inet 192.168.77.232/24 brd 192.168.77.255 scope global wlan0\n' >"$LOG/ips"
  printf '200' >"$LOG/code"
  printf 'active\n' >"$LOG/tun"
  printf 'inactive\n' >"$LOG/relay"
  printf '2000' >"$LOG/saved-fast"
  printf '3000' >"$LOG/saved-other"
  rm -rf "$TMP/run" "$LOG/actions" "$LOG/start_fails"
  cat >"$LOG/dump" <<'DUMP'
  running     port 1080 · ↓ 0 B · ↑ 0 B · 0 clients
  saved       "daily" — port 1080 · SSID PhoneLink · user proxy · auto-start on · wireless debugging off
  saved       "fast" — port 2000 · SSID PhoneLink · user proxy · auto-start off · wireless debugging off
  saved       "other" — port 3000 · SSID PhoneLink · user alice · auto-start off · wireless debugging off
  auto-start  true
DUMP
}

line_of() {
  grep -n -e "$1" "$LOG/actions" | head -1 | cut -d: -f1
}

# 1. A port nothing listens on is refused before the phone is touched.
fresh
if run --port 1081; then bad "a closed port exits 1"; else ok "a closed port exits 1"; fi
grep -q 'not listening on port 1081' "$LOG/out" && ok "says nothing listens there" \
  || bad "says nothing listens there" "$(cat "$LOG/out")"
[ -s "$LOG/actions" ] && bad "a closed port sends nothing" || ok "a closed port sends nothing"
[ -e "$PHONE_RUNTIME_PORT_FILE" ] && bad "a closed port writes no runtime port" \
  || ok "a closed port writes no runtime port"

# 2. A port the phone listens on, with the laptop's credentials: the request
#    comes first, then the tunnel restart, then the old port goes.
fresh
printf '  running     port 1081 · ↓ 0 B · ↑ 0 B · 0 clients\n' >>"$LOG/dump"
if run --port 1081; then ok "switching to a listening port exits 0"; else
  bad "switching to a listening port exits 0" "$(cat "$LOG/out")"
fi
[ "$(runtime_port)" = 1081 ] && ok "writes the runtime port" \
  || bad "writes the runtime port" "$(runtime_port)"
grep -q 'port 1081 answered through 192.168.77.232' "$LOG/out" && ok "reports the answering address" \
  || bad "reports the answering address" "$(cat "$LOG/out")"
curl_line=$(line_of '^curl ')
restart_line=$(line_of 'systemctl restart phone-tun.service')
stop_line=$(line_of 'STOP --ei port 1080')
[ -n "$curl_line" ] && [ -n "$restart_line" ] && [ "$curl_line" -lt "$restart_line" ] \
  && ok "a request answers before the tunnel is restarted" \
  || bad "a request answers before the tunnel is restarted" "$(cat "$LOG/actions")"
[ -n "$stop_line" ] && [ "$restart_line" -lt "$stop_line" ] \
  && ok "the old port is dropped after the restart" \
  || bad "the old port is dropped after the restart" "$(cat "$LOG/actions")"
grep -q 'port 1080 ·' "$LOG/dump" && bad "the old listener is gone from the dump" \
  || ok "the old listener is gone from the dump"
grep -q 'systemctl restart phone-socks-relay.service' "$LOG/actions" \
  && bad "an inactive relay is not restarted" || ok "an inactive relay is not restarted"
grep -q 's3cret' "$LOG/out" && bad "the password stays out of the log" \
  || ok "the password stays out of the log"

# 3. A saved proxy that is not running is started by name, then used.
fresh
if run --profile fast; then ok "starting a saved proxy exits 0"; else
  bad "starting a saved proxy exits 0" "$(cat "$LOG/out")"
fi
grep -q -- '-a org.phonelink.proxy.action.START --es profile fast' "$LOG/actions" \
  && ok "starts the saved configuration by name" || bad "starts the saved configuration by name" "$(cat "$LOG/actions")"
[ "$(runtime_port)" = 2000 ] && ok "writes the saved proxy's port" \
  || bad "writes the saved proxy's port" "$(runtime_port)"
grep -q 'port 2000 ·' "$LOG/dump" && ok "the listener is up on its port" \
  || bad "the listener is up on its port" "$(cat "$LOG/dump")"

# 4. A saved proxy with another user is refused up front: adb never prints its
#    password, so starting it would only prove the laptop cannot use it.
fresh
if run --profile other; then bad "a foreign user exits 1"; else ok "a foreign user exits 1"; fi
grep -q 'it uses user alice' "$LOG/out" && ok "names the user it would need" \
  || bad "names the user it would need" "$(cat "$LOG/out")"
[ -s "$LOG/actions" ] && bad "a foreign user starts nothing" || ok "a foreign user starts nothing"
[ -e "$PHONE_RUNTIME_PORT_FILE" ] && bad "a foreign user writes no runtime port" \
  || ok "a foreign user writes no runtime port"

# 5. A phone that cannot start the saved proxy: what the switch started is
#    stopped again, and the laptop keeps its port.
fresh
: >"$LOG/start_fails"
if run --profile fast; then bad "a failed start exits 1"; else ok "a failed start exits 1"; fi
grep -q 'could not start "fast" on port 2000' "$LOG/out" && ok "says the start failed" \
  || bad "says the start failed" "$(cat "$LOG/out")"
grep -q -- 'STOP --ei port 2000' "$LOG/actions" && ok "stops what it started" \
  || bad "stops what it started" "$(cat "$LOG/actions")"
[ -e "$PHONE_RUNTIME_PORT_FILE" ] && bad "a failed start writes no runtime port" \
  || ok "a failed start writes no runtime port"
grep -q 'systemctl restart' "$LOG/actions" && bad "a failed start restarts nothing" \
  || ok "a failed start restarts nothing"

# 6. A listener that starts but refuses the password: refused, and stopped.
fresh
rm -f "$LOG/start_fails"
printf '000' >"$LOG/code"
if run --profile fast; then bad "a refused password exits 1"; else ok "a refused password exits 1"; fi
grep -q 'did not answer through port 2000' "$LOG/out" && ok "says the request failed" \
  || bad "says the request failed" "$(cat "$LOG/out")"
grep -q -- 'STOP --ei port 2000' "$LOG/actions" && ok "stops the proxy it started" \
  || bad "stops the proxy it started" "$(cat "$LOG/actions")"
[ -e "$PHONE_RUNTIME_PORT_FILE" ] && bad "a refused password writes no runtime port" \
  || ok "a refused password writes no runtime port"

# 7. A running port the switch did not start is left alone when it fails.
fresh
printf '  running     port 1081 · 0 clients\n' >>"$LOG/dump"
printf '000' >"$LOG/code"
if run --port 1081; then bad "an unanswered switch exits 1"; else ok "an unanswered switch exits 1"; fi
grep -q -- 'STOP' "$LOG/actions" && bad "a listener it did not start is not stopped" \
  || ok "a listener it did not start is not stopped"

# 8. --check compares the laptop's port with the phone's listeners, read-only.
fresh
if run --check; then ok "--check on a match exits 0"; else bad "--check on a match exits 0" "$(cat "$LOG/out")"; fi
grep -q 'laptop port 1080' "$LOG/out" && ok "prints the laptop's port" \
  || bad "prints the laptop's port" "$(cat "$LOG/out")"
grep -q 'phone ports  1080' "$LOG/out" && ok "prints the phone's ports" \
  || bad "prints the phone's ports" "$(cat "$LOG/out")"
[ -s "$LOG/actions" ] && bad "--check sends nothing" || ok "--check sends nothing"
fresh
grep -v 'port 1080 ·' "$LOG/dump" >"$LOG/dump.new" && mv "$LOG/dump.new" "$LOG/dump"
if run --check; then bad "--check on a mismatch exits 1"; else ok "--check on a mismatch exits 1"; fi
grep -q 'the laptop and the phone disagree' "$LOG/out" && ok "says they disagree" \
  || bad "says they disagree" "$(cat "$LOG/out")"
[ -e "$PHONE_RUNTIME_PORT_FILE" ] && bad "--check writes no runtime port" \
  || ok "--check writes no runtime port"

# 9. The old port is the one the laptop was using, not the built-in default:
#    after a switch the runtime file is what the next one moves away from.
fresh
mkdir -p "$(dirname "$PHONE_RUNTIME_PORT_FILE")"
printf '1081\n' >"$PHONE_RUNTIME_PORT_FILE"
printf '  running     port 1081 · 0 clients\n' >>"$LOG/dump"
if run --port 2000; then bad "an unstarted port is refused" "should not switch"; else
  ok "an unstarted port is refused"
fi
printf '  running     port 2000 · 0 clients\n' >>"$LOG/dump"
if run --port 2000; then ok "switching from a runtime port exits 0"; else
  bad "switching from a runtime port exits 0" "$(cat "$LOG/out")"
fi
grep -q -- 'STOP --ei port 1081' "$LOG/actions" && ok "drops the port that was in use" \
  || bad "drops the port that was in use" "$(cat "$LOG/actions")"
[ "$(runtime_port)" = 2000 ] && ok "keeps the runtime file in step" \
  || bad "keeps the runtime file in step" "$(runtime_port)"

# 10. --list is the panel's view: the active port, the listeners, and which
#     saved proxies the laptop can authenticate to.
fresh
if run --list; then ok "--list exits 0"; else bad "--list exits 0" "$(cat "$LOG/out")"; fi
grep -q '"active": 1080' "$LOG/out" && ok "lists the active port" \
  || bad "lists the active port" "$(cat "$LOG/out")"
grep -q '"running": \[' "$LOG/out" && grep -q '1080' "$LOG/out" \
  && ok "lists the phone's listeners" || bad "lists the phone's listeners" "$(cat "$LOG/out")"
grep -q '"name": "fast"' "$LOG/out" && ok "lists the saved proxies by name" \
  || bad "lists the saved proxies by name" "$(cat "$LOG/out")"
grep -q '"offerable": false' "$LOG/out" && ok "marks a proxy it has no password for" \
  || bad "marks a proxy it has no password for" "$(cat "$LOG/out")"
grep -q '"offerable": true' "$LOG/out" && ok "marks the ones it can use" \
  || bad "marks the ones it can use" "$(cat "$LOG/out")"
[ -s "$LOG/actions" ] && bad "--list sends nothing" || ok "--list sends nothing"

# 11. A phone that is not there, and a name that is not saved.
fresh
printf 'List of devices attached\n' >"$LOG/devices"
if run --port 1081; then bad "no phone exits 1"; else ok "no phone exits 1"; fi
grep -q 'no phone attached' "$LOG/out" && ok "says there is no phone" \
  || bad "says there is no phone" "$(cat "$LOG/out")"
fresh
if run --profile nosuch; then bad "an unknown profile exits 1"; else ok "an unknown profile exits 1"; fi
grep -q 'no saved proxy called "nosuch"' "$LOG/out" && ok "names the saved ones" \
  || bad "names the saved ones" "$(cat "$LOG/out")"

# 12. Nothing chosen, and nonsense arguments.
fresh
if run; then bad "no target exits 1"; else ok "no target exits 1"; fi
grep -q 'choose a port' "$LOG/out" && ok "says what to choose" || bad "says what to choose" "$(cat "$LOG/out")"
if run --port http; then bad "a non-numeric port exits 1"; else ok "a non-numeric port exits 1"; fi
if run --bogus; then bad "an unknown argument exits 1"; else ok "an unknown argument exits 1"; fi
if run --help; then ok "--help exits 0"; else bad "--help exits 0"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
