#!/usr/bin/env bash
# Hermetic tests for bin/phone-link-uninstall: stub nmcli/systemctl/sudo.
set -u

BASH_BIN=$(command -v bash)
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/bin/phone-link-uninstall
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export LOG=$TMP/log STUBS=$TMP/bin HOME=$TMP
export PHONE_SECRETS=$TMP/secrets
export PHONE_APK_CACHE=$TMP/cache
export PHONE_AP_DECLARATIVE=$TMP/ap-profile
export PHONE_NM_SYSTEM_CONNECTIONS=$TMP/etc-connections
export PHONE_NM_RUN_CONNECTIONS=$TMP/run-connections
mkdir -p "$LOG" "$STUBS" "$PHONE_APK_CACHE" "$PHONE_NM_SYSTEM_CONNECTIONS" "$PHONE_NM_RUN_CONNECTIONS"
printf 'PHONE_SOCKS_PASS=pass\nPHONE_PIN=1234\nPHONE_AP_PASS=ap-secret\n' >"$PHONE_SECRETS"
chmod 600 "$PHONE_SECRETS"
printf 'apk\n' >"$PHONE_APK_CACHE/proxy.apk"

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
  "-t -f NAME,DEVICE con show --active") cat "$LOG/active" ;;
  "connection down "*)
    printf '%s\n' "$*" >>"$LOG/actions"
    : >"$LOG/active"
    ;;
  "connection delete "*)
    printf '%s\n' "$*" >>"$LOG/actions"
    : >"$LOG/names"
    ;;
  "connection reload") printf '%s\n' "$*" >>"$LOG/actions" ;;
esac
EOF

cat >"$STUBS/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$LOG/actions"
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

run() {
  "$BASH_BIN" "$SCRIPT" "$@" >"$LOG/out" 2>&1
}

# 1. --check reports the profile, declaration and cache without changing them.
printf 'phonelink\nother\n' >"$LOG/names"
printf 'phonelink:wlp110s0\n' >"$LOG/active"
printf 'phonelink\n' >"$PHONE_AP_DECLARATIVE"
rm -f "$LOG/actions"
if run --check; then ok "--check exits 0"; else bad "--check exits 0" "$(cat "$LOG/out")"; fi
grep -q 'phonelink exists and is active on wlp110s0' "$LOG/out" \
  && ok "reports the active profile" || bad "reports the active profile" "$(cat "$LOG/out")"
grep -q 'still declares' "$LOG/out" \
  && ok "reports the declaration" || bad "reports the declaration"
grep -q 'exists' "$LOG/out" && [ -s "$PHONE_APK_CACHE/proxy.apk" ] \
  && ok "reports the cache" || bad "reports the cache"
[ -s "$LOG/actions" ] && bad "--check changes nothing" || ok "--check changes nothing"

# 2. A still-declared profile is refused: it would return at the next boot.
rm -f "$LOG/actions"
if run --yes; then bad "declared uninstall exits 1"; else ok "declared uninstall exits 1"; fi
grep -q 'remove it from configuration.nix' "$LOG/out" \
  && ok "explains the declarative guard" || bad "explains the declarative guard"
[ -s "$LOG/actions" ] && bad "declared uninstall changes nothing" \
  || ok "declared uninstall changes nothing"

# 3. --yes stops the units, deletes the profile and clears the cache.
rm -f "$PHONE_AP_DECLARATIVE" "$LOG/actions"
printf 'phonelink\nother\n' >"$LOG/names"
printf 'phonelink:wlp110s0\n' >"$LOG/active"
if run --yes; then ok "uninstall exits 0"; else bad "uninstall exits 0" "$(cat "$LOG/out")"; fi
for unit in phone-tun-toggle.timer phone-tun-toggle.service phone-tun.service; do
  grep -qx "stop $unit" "$LOG/actions" && ok "stops $unit" || bad "stops $unit" "$(cat "$LOG/actions" 2>/dev/null)"
done
grep -qx 'connection down phonelink' "$LOG/actions" && ok "brings the AP down" \
  || bad "brings the AP down" "$(cat "$LOG/actions" 2>/dev/null)"
grep -qx 'connection delete phonelink' "$LOG/actions" && ok "deletes the profile" \
  || bad "deletes the profile" "$(cat "$LOG/actions" 2>/dev/null)"
[ -s "$LOG/names" ] && bad "profile is gone afterwards" || ok "profile is gone afterwards"
[ -e "$PHONE_APK_CACHE" ] && bad "cache is gone" || ok "cache is gone"
[ -f "$PHONE_SECRETS" ] && ok "keeps the secrets file" || bad "keeps the secrets file"
grep -q 'kept ' "$LOG/out" && ok "prints the kept secrets" || bad "prints the kept secrets"
grep -q 'phone-wifi-forget' "$LOG/out" && ok "prints the phone-side steps" \
  || bad "prints the phone-side steps"

# 4. --keep-cache leaves the APKs in place.
mkdir -p "$PHONE_APK_CACHE"
printf 'apk\n' >"$PHONE_APK_CACHE/proxy.apk"
printf 'phonelink\n' >"$LOG/names"
: >"$LOG/active"
rm -f "$LOG/actions"
if run --yes --keep-cache; then ok "--keep-cache exits 0"; else bad "--keep-cache exits 0"; fi
[ -f "$PHONE_APK_CACHE/proxy.apk" ] && ok "keeps the cache" || bad "keeps the cache"

# 5. No profile: nothing to delete.
: >"$LOG/names"
rm -f "$LOG/actions"
if run --yes; then ok "missing profile exits 0"; else bad "missing profile exits 0"; fi
grep -q 'connection delete' "$LOG/actions" && bad "missing profile deletes nothing" \
  || ok "missing profile deletes nothing"

# 6. Without --yes in a non-interactive shell it refuses.
printf 'phonelink\n' >"$LOG/names"
rm -f "$LOG/actions"
if run >/dev/null 2>&1; then bad "no --yes exits 1"; else ok "no --yes exits 1"; fi
[ -s "$LOG/actions" ] && bad "no --yes changes nothing" || ok "no --yes changes nothing"

# 7. --help.
if run --help; then ok "--help exits 0"; else bad "--help exits 0"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
