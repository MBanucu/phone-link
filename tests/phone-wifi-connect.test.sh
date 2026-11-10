#!/usr/bin/env bash
# Hermetic tests for bin/phone-wifi-connect: stub adb with wifi status and a
# connect-network handler that checks the passphrase it was given.
set -u

BASH_BIN=$(command -v bash)
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/bin/phone-wifi-connect
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
  shell)
    args=("${args[@]:1}")
    cmdline="${args[*]}"
    case "$cmdline" in
      "cmd wifi status") cat "$LOG/status" ;;
      "cmd wifi set-wifi-enabled enabled") printf 'set-wifi-enabled enabled\n' >>"$LOG/actions" ;;
      cmd\ wifi\ connect-network*)
        printf '%s\n' "$cmdline" >>"$LOG/actions"
        ssid=$(printf '%s' "$cmdline" | sed "s/.*connect-network '\([^']*\)'.*/\1/")
        pass=$(printf '%s' "$cmdline" | sed "s/.*wpa2 '\(.*\)'$/\1/")
        if [ "$pass" = "$(cat "$LOG/pass")" ]; then
          printf 'Wifi is enabled\nWifi is connected to "%s", frequency: 5180\n' "$ssid" >"$LOG/status"
        fi
        ;;
    esac
    ;;
esac
EOF
sed -i "1s|.*|#!$BASH_BIN|" "$STUBS/adb"
chmod +x "$STUBS/adb"
export PATH="$STUBS:$PATH"

fresh_state() {
  printf 'List of devices attached\nXPLO2EEA0001541\tdevice\n' >"$LOG/devices"
  printf 'Wifi is enabled\nWifi is not connected\n' >"$LOG/status"
  printf 'ap-secret\n' >"$LOG/pass"
  rm -f "$LOG/actions"
  export PHONE_AP_PASS=ap-secret
  export PHONE_SECRETS=$TMP/absent-secrets
}

run() {
  "$BASH_BIN" "$SCRIPT" "$@" >"$LOG/out" 2>&1
}

# 1. --check reports a missing association and changes nothing.
fresh_state
if run --check; then
  bad "--check exits 1 when not connected"
else
  ok "--check exits 1 when not connected"
fi
grep -q 'not connected to PhoneLink' "$LOG/out" && ok "reports not connected" \
  || bad "reports not connected" "$(cat "$LOG/out")"
[ ! -f "$LOG/actions" ] && ok "--check changes nothing" || bad "--check changes nothing"

# 2. Connecting uses the stored password and waits for the association.
if run; then
  ok "connect exits 0"
else
  bad "connect exits 0" "$(cat "$LOG/out")"
fi
grep -q "connect-network 'PhoneLink' wpa2 'ap-secret'" "$LOG/actions" \
  && ok "quotes SSID and passphrase for the remote shell" \
  || bad "quotes SSID and passphrase for the remote shell" "$(cat "$LOG/actions" 2>/dev/null)"
grep -q 'connected to PhoneLink' "$LOG/out" && ok "reports the association" \
  || bad "reports the association" "$(cat "$LOG/out")"

# 3. --check now exits 0.
if run --check; then ok "--check exits 0 when connected"; else bad "--check exits 0 when connected" "$(cat "$LOG/out")"; fi

# 4. Already connected: no new command.
rm -f "$LOG/actions"
if run; then ok "second connect exits 0"; else bad "second connect exits 0" "$(cat "$LOG/out")"; fi
grep -q 'already connected to PhoneLink' "$LOG/out" && ok "says already connected" \
  || bad "says already connected" "$(cat "$LOG/out")"
[ ! -f "$LOG/actions" ] && ok "second connect runs no command" || bad "second connect runs no command"

# 5. A passphrase with spaces stays one argument.
fresh_state
export PHONE_AP_PASS='ap pass'
printf 'ap pass\n' >"$LOG/pass"
if run; then ok "spaced passphrase exits 0"; else bad "spaced passphrase exits 0" "$(cat "$LOG/out")"; fi
grep -q "wpa2 'ap pass'" "$LOG/actions" && ok "spaced passphrase is quoted" \
  || bad "spaced passphrase is quoted" "$(cat "$LOG/actions")"

# 6. A wrong passphrase fails instead of hanging.
fresh_state
export PHONE_AP_PASS=wrong
if PHONE_WIFI_TRIES=2 PHONE_WIFI_POLL=1 run; then
  bad "wrong passphrase exits 1"
else
  ok "wrong passphrase exits 1"
fi
grep -q 'could not connect to PhoneLink' "$LOG/out" && ok "explains the failure" \
  || bad "explains the failure" "$(cat "$LOG/out")"

# 7. No password anywhere is an error before any command.
fresh_state
unset PHONE_AP_PASS
export PHONE_SECRETS=$TMP/absent-secrets
if run; then bad "missing password exits 1"; else ok "missing password exits 1"; fi
grep -q 'PHONE_AP_PASS' "$LOG/out" && ok "points at PHONE_AP_PASS" \
  || bad "points at PHONE_AP_PASS" "$(cat "$LOG/out")"
[ ! -f "$LOG/actions" ] && ok "no command without a password" || bad "no command without a password"

# 8. No phone.
printf 'List of devices attached\n' >"$LOG/devices"
if run; then bad "no phone exits 1"; else ok "no phone exits 1"; fi
grep -q 'no phone attached' "$LOG/out" && ok "no phone message" || bad "no phone message" "$(cat "$LOG/out")"

# 9. --help exits 0.
if run --help; then ok "--help exits 0"; else bad "--help exits 0"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
