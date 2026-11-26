#!/usr/bin/env bash
# Hermetic tests for bin/phone-proxy-setup: stub adb with the app's intents,
# the dump they produce and the LAN address, plus a stub curl for the request
# through the listener. No phone, no screen, no keyguard.
set -u

BASH_BIN=$(command -v bash)
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/bin/phone-proxy-setup
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

# The app takes the extras of its START intent and prints them back: the dump
# after a start is the configuration it was given, exactly like ProxyService.
cat >"$STUBS/adb" <<'EOF'
#!/usr/bin/env bash
args=("$@")
if [ "${args[0]:-}" = "-s" ]; then args=("${args[@]:2}"); fi
cmd="${args[*]}"
case $cmd in
  "devices") printf 'List of devices attached\nXPLO2EEA0001541\tdevice\n' ;;
  "shell pm path "*) cat "$LOG/pm" ;;
  "shell dumpsys activity service "*) cat "$LOG/dump" ;;
  "shell ip -4 -o addr show 2>/dev/null"*) cat "$LOG/ips" ;;
  "shell am start-foreground-service "*)
    printf '%s\n' "$cmd" >>"$LOG/actions"
    port=$(sed -n 's/.*--ei port \([0-9][0-9]*\).*/\1/p' <<<"$cmd")
    user=$(sed -n 's/.*--es user \([^ ]*\).*/\1/p' <<<"$cmd")
    auto=$(sed -n 's/.*--ez auto_start \([a-z]*\).*/\1/p' <<<"$cmd")
    max=$(sed -n 's/.*--ei max_connections \([0-9][0-9]*\).*/\1/p' <<<"$cmd")
    if grep -q 'anonymous true' <<<"$cmd"; then who="no authentication"; else who="user $user"; fi
    {
      printf '  state       "laptop" listening on 0.0.0.0:%s · 0 clients\n' "$port"
      printf '  using       port %s · SSID PhoneLink · %s\n' "$port" "$who"
      # Only an app that was asked for the ceiling prints it; the older build
      # ignores the extra and prints no line at all.
      if [ -n "$max" ]; then printf '  max_connections %s\n' "$max"; fi
      printf '  auto-start  %s\n' "$auto"
    } >"$LOG/dump"
    ;;
esac
EOF
sed -i "1s|.*|#!$BASH_BIN|" "$STUBS/adb"

cat >"$STUBS/curl" <<'EOF'
#!/usr/bin/env bash
# What a request through the listener answers; $LOG/code says whether the
# phone accepted the credentials.
printf '%s' "$(cat "$LOG/code")"
EOF
sed -i "1s|.*|#!$BASH_BIN|" "$STUBS/curl"
chmod +x "$STUBS"/*
export PATH="$STUBS:$PATH"

printf 'PHONE_SOCKS_PASS=s3cret\n' >"$TMP/secrets"
export PHONE_SECRETS=$TMP/secrets
# The credentials the daily proxy uses, so the defaults under test are the
# ones a real setup has rather than the built-in fallbacks.
export PHONE_PROXY_PORT=1081 PHONE_PROXY_USER=proxy

run() {
  "$BASH_BIN" "$SCRIPT" "$@" >"$LOG/out" 2>&1
}

fresh() {
  printf 'package:/data/app/base.apk\n' >"$LOG/pm"
  : >"$LOG/dump"
  : >"$LOG/actions"
  printf '2: wlan0    inet 192.168.77.232/24 brd 192.168.77.255 scope global wlan0\n' >"$LOG/ips"
  printf '200' >"$LOG/code"
}

# 1. A setup is the app's intent with the secrets file's password, verified
# through the listener rather than taken on trust.
fresh
if run; then ok "setup exits 0"; else bad "setup exits 0" "$(cat "$LOG/out")"; fi
grep -q -- '-a org.phonelink.proxy.action.START --ei port 1081 --es user proxy --es password s3cret --ez anonymous false --ez auto_start true$' \
  "$LOG/actions" && ok "sends the configuration as extras" \
  || bad "sends the configuration as extras" "$(cat "$LOG/actions")"
grep -q 'no LAN address' "$LOG/out" && bad "reports a verified request" || ok "reports a verified request"
grep -q 'configured and verified through 192.168.77.232' "$LOG/out" \
  && ok "says which address answered" || bad "says which address answered" "$(cat "$LOG/out")"
grep -q 'password 6 chars' "$LOG/out" && ok "counts the password instead of printing it" \
  || bad "counts the password instead of printing it" "$(cat "$LOG/out")"
grep -q 's3cret' "$LOG/out" && bad "keeps the password out of the log" || ok "keeps the password out of the log"

# 2. --no-auto-start turns it off in the intent.
fresh
if run --no-auto-start; then ok "--no-auto-start exits 0"; else bad "--no-auto-start exits 0" "$(cat "$LOG/out")"; fi
grep -q -- '--ez auto_start false$' "$LOG/actions" && ok "sends auto_start false" \
  || bad "sends auto_start false" "$(cat "$LOG/actions")"

# 3. --port and --user are what the app is asked for and what is verified.
fresh
if run --port 18080 --user who; then ok "custom port exits 0"; else bad "custom port exits 0" "$(cat "$LOG/out")"; fi
grep -q -- '--ei port 18080 --es user who ' "$LOG/actions" && ok "sends the custom port and user" \
  || bad "sends the custom port and user" "$(cat "$LOG/actions")"
grep -q '192.168.77.232:18080 -> https://example.com = 200' "$LOG/out" \
  && ok "verifies through the port it chose" || bad "verifies through the port it chose" "$(cat "$LOG/out")"

# 4. A listener that answers nothing is a failure, not a success.
fresh
printf '000' >"$LOG/code"
if run; then bad "an unanswered request exits 1"; else ok "an unanswered request exits 1"; fi
grep -q 'no LAN address answered with 200' "$LOG/out" && ok "says the request failed" \
  || bad "says the request failed" "$(cat "$LOG/out")"

# 5. --check reads the dump and agrees with what is there.
fresh
printf '  state       "laptop" listening on 0.0.0.0:1081 · 0 clients\n  using       port 1081 · SSID PhoneLink · user proxy\n  auto-start  true\n' >"$LOG/dump"
if run --check; then ok "--check on a match exits 0"; else bad "--check on a match exits 0" "$(cat "$LOG/out")"; fi
grep -q 'port       1081 (want 1081)' "$LOG/out" && ok "prints the port" || bad "prints the port" "$(cat "$LOG/out")"
grep -q 'username   proxy (want proxy)' "$LOG/out" && ok "prints the user" || bad "prints the user" "$(cat "$LOG/out")"
grep -q 'auto-start true (want true)' "$LOG/out" && ok "prints auto-start" || bad "prints auto-start" "$(cat "$LOG/out")"
grep -q 'max-connections <unknown>' "$LOG/out" && ok "says an old app has no ceiling" \
  || bad "says an old app has no ceiling" "$(cat "$LOG/out")"
grep -q 'request    200 (want 200)' "$LOG/out" && ok "checks a request" || bad "checks a request" "$(cat "$LOG/out")"
[ -s "$LOG/actions" ] && bad "--check sends nothing" || ok "--check sends nothing"

# 6. --check catches a port that is not the one asked for.
fresh
printf '  state       "laptop" listening on 0.0.0.0:1081 · 0 clients\n  using       port 1081 · SSID PhoneLink · user proxy\n  auto-start  true\n' >"$LOG/dump"
if run --check --port 1080; then bad "--check on a mismatch exits 1"; else ok "--check on a mismatch exits 1"; fi

# 7. A credentials file without the password is named.
fresh
printf 'OTHER=1\n' >"$TMP/empty"
if PHONE_SECRETS=$TMP/empty run; then bad "a missing password exits 1"; else ok "a missing password exits 1"; fi
grep -q 'PHONE_SOCKS_PASS' "$LOG/out" && ok "names the missing key" || bad "names the missing key" "$(cat "$LOG/out")"
[ -s "$LOG/actions" ] && bad "nothing is sent without a password" || ok "nothing is sent without a password"

# 8. Nonsense arguments are refused before anything is sent.
fresh
if run --port http; then bad "a non-numeric port exits 1"; else ok "a non-numeric port exits 1"; fi
grep -q 'port must be numeric: http' "$LOG/out" && ok "says why" || bad "says why" "$(cat "$LOG/out")"
if run --port 70000; then bad "an out-of-range port exits 1"; else ok "an out-of-range port exits 1"; fi
[ -s "$LOG/actions" ] && bad "nothing is sent for a bad port" || ok "nothing is sent for a bad port"

# 9. --help and unknown arguments.
if run --help; then ok "--help exits 0"; else bad "--help exits 0"; fi
if run --bogus; then bad "unknown argument exits 1"; else ok "unknown argument exits 1"; fi

# 10. --max-connections is sent as its own extra and read back from the app.
fresh
if run --max-connections 512; then ok "a ceiling exits 0"; else bad "a ceiling exits 0" "$(cat "$LOG/out")"; fi
grep -q -- '--ez auto_start true --ei max_connections 512$' "$LOG/actions" \
  && ok "sends max_connections after the other extras" \
  || bad "sends max_connections after the other extras" "$(cat "$LOG/actions")"
grep -q 'max-connections 512' "$LOG/out" && ok "reports the ceiling it set" \
  || bad "reports the ceiling it set" "$(cat "$LOG/out")"

# 11. Without the flag the intent is unchanged: no extra, and an app that does
# not know the setting keeps its saved value.
fresh
if run; then ok "a setup without a ceiling exits 0"; else bad "a setup without a ceiling exits 0" "$(cat "$LOG/out")"; fi
grep -q 'max_connections' "$LOG/actions" \
  && bad "a setup without the flag sends no ceiling" \
  || ok "a setup without the flag sends no ceiling"
grep -q 'max_connections' "$LOG/dump" \
  && bad "an old app's dump carries no ceiling line" \
  || ok "an old app's dump carries no ceiling line"

# 12. --check compares the ceiling only when one was asked for.
fresh
printf '  state       "laptop" listening on 0.0.0.0:1081 · 0 clients\n  using       port 1081 · SSID PhoneLink · user proxy\n  max_connections 512\n  auto-start  true\n' >"$LOG/dump"
if run --check --max-connections 512; then ok "--check on a matching ceiling exits 0"; else bad "--check on a matching ceiling exits 0" "$(cat "$LOG/out")"; fi
grep -q 'max-connections 512 (want 512)' "$LOG/out" && ok "prints the ceiling and what was asked for" \
  || bad "prints the ceiling and what was asked for" "$(cat "$LOG/out")"
[ -s "$LOG/actions" ] && bad "--check with a ceiling sends nothing" || ok "--check with a ceiling sends nothing"

fresh
printf '  state       "laptop" listening on 0.0.0.0:1081 · 0 clients\n  using       port 1081 · SSID PhoneLink · user proxy\n  max_connections 256\n  auto-start  true\n' >"$LOG/dump"
if run --check --max-connections 512; then bad "--check on a different ceiling exits 1"; else ok "--check on a different ceiling exits 1"; fi
grep -q 'max-connections 256 (want 512)' "$LOG/out" && ok "says which ceiling the phone has" \
  || bad "says which ceiling the phone has" "$(cat "$LOG/out")"

fresh
printf '  state       "laptop" listening on 0.0.0.0:1081 · 0 clients\n  using       port 1081 · SSID PhoneLink · user proxy\n  max_connections 512\n  auto-start  true\n' >"$LOG/dump"
if run --check; then ok "--check without a ceiling ignores the value"; else bad "--check without a ceiling ignores the value" "$(cat "$LOG/out")"; fi
grep -q 'max-connections 512$' "$LOG/out" && ok "reports the ceiling informationally" \
  || bad "reports the ceiling informationally" "$(cat "$LOG/out")"

# 13. Nonsense ceilings are refused before anything is sent.
fresh
if run --max-connections abc; then bad "a non-numeric ceiling exits 1"; else ok "a non-numeric ceiling exits 1"; fi
grep -q 'max_connections must be numeric: abc' "$LOG/out" && ok "says why a ceiling is not numeric" \
  || bad "says why a ceiling is not numeric" "$(cat "$LOG/out")"
[ -s "$LOG/actions" ] && bad "nothing is sent for a bad ceiling" || ok "nothing is sent for a bad ceiling"

fresh
if run --max-connections 15; then bad "a ceiling below 16 exits 1"; else ok "a ceiling below 16 exits 1"; fi
grep -q 'max_connections must be 16\.\.1024, got 15' "$LOG/out" && ok "names the range for 15" \
  || bad "names the range for 15" "$(cat "$LOG/out")"

fresh
if run --max-connections 1025; then bad "a ceiling above 1024 exits 1"; else ok "a ceiling above 1024 exits 1"; fi
grep -q 'max_connections must be 16\.\.1024, got 1025' "$LOG/out" && ok "names the range for 1025" \
  || bad "names the range for 1025" "$(cat "$LOG/out")"
[ -s "$LOG/actions" ] && bad "nothing is sent for an out-of-range ceiling" \
  || ok "nothing is sent for an out-of-range ceiling"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
