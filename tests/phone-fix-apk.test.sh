#!/usr/bin/env bash
# Hermetic tests for bin/phone-fix-apk: stub phone-proxy-install, use a
# temporary cache directory. No network, no root.
set -u

BASH_BIN=$(command -v bash)
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/bin/phone-fix-apk
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export LOG=$TMP/log STUBS=$TMP/bin HOME=$TMP
export PHONE_APK_CACHE=$TMP/cache
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

cat >"$STUBS/phone-proxy-install" <<'EOF'
#!/usr/bin/env bash
printf 'phone-proxy-install %s\n' "$*" >>"$LOG/actions"
mkdir -p "$PHONE_APK_DIR"
: >"$PHONE_APK_DIR/com.tokyoxpa3.androidproxy-1.7.4-24.apk"
EOF

sed -i "1s|.*|#!$BASH_BIN|" "$STUBS"/*
chmod +x "$STUBS"/*
export PATH="$STUBS:$PATH"

run() {
  "$BASH_BIN" "$SCRIPT" "$@" >"$LOG/out" 2>&1
}

# 1. Empty cache: --check reports it without downloading.
rm -rf "$PHONE_APK_CACHE"
if run --check; then bad "empty --check exits 1"; else ok "empty --check exits 1"; fi
[ -e "$LOG/actions" ] && bad "empty --check downloads nothing" || ok "empty --check downloads nothing"

# 2. Empty cache: the fix downloads into the ambulance box.
if run; then ok "stocks an empty cache"; else bad "stocks an empty cache" "$(cat "$LOG/out")"; fi
grep -q 'phone-proxy-install --fdroid --check' "$LOG/actions" \
  && ok "asks F-Droid for the APK" || bad "asks F-Droid for the APK" "$(cat "$LOG/actions" 2>/dev/null)"
ls "$PHONE_APK_CACHE"/*.apk >/dev/null 2>&1 && ok "leaves an APK in the cache" \
  || bad "leaves an APK in the cache"

# 3. Stocked cache: no download.
rm -f "$LOG/actions"
if run; then ok "stocked cache exits 0"; else bad "stocked cache exits 0" "$(cat "$LOG/out")"; fi
[ -s "$LOG/actions" ] && bad "stocked cache downloads nothing" || ok "stocked cache downloads nothing"
if run --check; then ok "stocked --check exits 0"; else bad "stocked --check exits 0"; fi

# 4. --refresh downloads again.
rm -f "$LOG/actions"
if run --refresh; then ok "--refresh exits 0"; else bad "--refresh exits 0" "$(cat "$LOG/out")"; fi
grep -q 'phone-proxy-install --fdroid --check' "$LOG/actions" \
  && ok "--refresh downloads" || bad "--refresh downloads"

# 5. --help.
if run --help; then ok "--help exits 0"; else bad "--help exits 0"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
