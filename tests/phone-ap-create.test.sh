#!/usr/bin/env bash
# Hermetic tests for bin/phone-ap-create: stub nmcli/sudo, temporary secrets.
set -u

BASH_BIN=$(command -v bash)
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/bin/phone-ap-create
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export LOG=$TMP/log STUBS=$TMP/bin HOME=$TMP
export PHONE_SECRETS=$TMP/secrets
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

cat >"$STUBS/nmcli" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "-t -f NAME con show") cat "$LOG/names" ;;
  "connection add "*)
    printf '%s\n' "$*" >>"$LOG/actions"
    printf 'phonelink\n' >"$LOG/names"
    ;;
  "connection modify "*) printf '%s\n' "$*" >>"$LOG/actions" ;;
  "-g 802-11-wireless.mode connection show phonelink") printf 'ap\n' ;;
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
printf 'PHONE_SOCKS_PASS=pass\nPHONE_PIN=1234\nPHONE_AP_PASS=ap-secret\n' >"$PHONE_SECRETS"
chmod 600 "$PHONE_SECRETS"

run() {
  "$BASH_BIN" "$SCRIPT" "$@" >"$LOG/out" 2>&1
}

# 1. Missing profile: created with the secret PSK and AP settings.
: >"$LOG/names"
rm -f "$LOG/actions"
if run; then ok "create exits 0"; else bad "create exits 0" "$(cat "$LOG/out")"; fi
grep -q '^connection add type wifi ifname wlp110s0 con-name phonelink' "$LOG/actions" \
  && ok "adds the AP profile" || bad "adds the AP profile" "$(cat "$LOG/actions" 2>/dev/null)"
grep -q 'ssid PhoneLink' "$LOG/actions" && ok "uses the AP SSID" || bad "uses the AP SSID"
grep -q '802-11-wireless.mode ap' "$LOG/actions" && ok "sets AP mode" \
  || bad "sets AP mode"
grep -q 'wifi-sec.psk ap-secret' "$LOG/actions" && ok "reads the PSK from secrets" \
  || bad "reads the PSK from secrets" "$(cat "$LOG/actions" 2>/dev/null)"
grep -q 'ipv4.addresses 192.168.77.1/24' "$LOG/actions" && ok "sets the AP address" \
  || bad "sets the AP address"
[ -s "$LOG/names" ] && ok "profile exists afterwards" || bad "profile exists afterwards"

# 2. Existing profile: no change without --refresh.
printf 'phonelink\n' >"$LOG/names"
rm -f "$LOG/actions"
if run; then ok "existing exits 0"; else bad "existing exits 0" "$(cat "$LOG/out")"; fi
[ -s "$LOG/actions" ] && bad "existing changes nothing" || ok "existing changes nothing"
grep -q 'already exists' "$LOG/out" && ok "says it already exists" \
  || bad "says it already exists" "$(cat "$LOG/out")"

# 3. --refresh rewrites the settings and PSK.
printf 'phonelink\n' >"$LOG/names"
rm -f "$LOG/actions"
if run --refresh; then ok "--refresh exits 0"; else bad "--refresh exits 0" "$(cat "$LOG/out")"; fi
grep -q '^connection modify phonelink' "$LOG/actions" && ok "modifies the profile" \
  || bad "modifies the profile" "$(cat "$LOG/actions" 2>/dev/null)"
grep -q 'wifi-sec.psk ap-secret' "$LOG/actions" && ok "--refresh updates the PSK" \
  || bad "--refresh updates the PSK"

# 4. --check is read-only and reports a missing profile.
: >"$LOG/names"
rm -f "$LOG/actions"
if run --check; then bad "missing --check exits 1"; else ok "missing --check exits 1"; fi
[ -s "$LOG/actions" ] && bad "--check changes nothing" || ok "--check changes nothing"
grep -q 'phonelink is missing' "$LOG/out" && ok "reports the missing profile" \
  || bad "reports the missing profile"

# 5. A missing secret is refused before any nmcli change.
: >"$LOG/names"
rm -f "$LOG/actions"
if PHONE_SECRETS=$TMP/missing run; then bad "missing secret exits 1"; else ok "missing secret exits 1"; fi
[ -s "$LOG/actions" ] && bad "missing secret changes nothing" || ok "missing secret changes nothing"

# 6. --help.
if run --help; then ok "--help exits 0"; else bad "--help exits 0"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
