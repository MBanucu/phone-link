#!/usr/bin/env bash
# Hermetic tests for bin/phone-fix-apk: a stand-in build, a temporary cache
# directory. No network, no root, no phone.
set -u

BASH_BIN=$(command -v bash)
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/bin/phone-fix-apk
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export LOG=$TMP/log STUBS=$TMP/bin HOME=$TMP
export PHONE_APK_CACHE=$TMP/cache
mkdir -p "$LOG" "$STUBS" "$TMP/build"
export PHONE_PROXY_APK=$TMP/build/phone-link-proxy.apk

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

run() {
  "$BASH_BIN" "$SCRIPT" "$@" >"$LOG/out" 2>&1
}

run_no_home() {
  env -u HOME -u XDG_CACHE_HOME "$BASH_BIN" "$SCRIPT" "$@" >"$LOG/out" 2>&1
}

printf 'build one\n' >"$PHONE_PROXY_APK"

# 1. Empty cache: --check reports it without copying anything.
rm -rf "$PHONE_APK_CACHE"
if run --check; then bad "empty --check exits 1"; else ok "empty --check exits 1"; fi
[ -e "$PHONE_APK_CACHE" ] && bad "empty --check copies nothing" || ok "empty --check copies nothing"

# 2. Empty cache: the fix puts this checkout's build in the ambulance box.
if run; then ok "stocks an empty cache"; else bad "stocks an empty cache" "$(cat "$LOG/out")"; fi
cmp -s "$PHONE_PROXY_APK" "$PHONE_APK_CACHE/phone-link-proxy.apk" \
  && ok "leaves the build in the cache" || bad "leaves the build in the cache" "$(ls -l "$PHONE_APK_CACHE" 2>&1)"
grep -q "ambulance APK ready: $PHONE_APK_CACHE/phone-link-proxy.apk" "$LOG/out" \
  && ok "says where it is" || bad "says where it is" "$(cat "$LOG/out")"

# 3. Stocked cache: a second run costs nothing.
rm -f "$PHONE_APK_CACHE/phone-link-proxy.apk"
printf 'old copy\n' >"$PHONE_APK_CACHE/phone-link-proxy.apk"
if run; then ok "stocked cache exits 0"; else bad "stocked cache exits 0" "$(cat "$LOG/out")"; fi
grep -q 'ambulance APK already stocked' "$LOG/out" && ok "leaves the copy alone" \
  || bad "leaves the copy alone" "$(cat "$LOG/out")"
grep -qx 'old copy' "$PHONE_APK_CACHE/phone-link-proxy.apk" && ok "the old copy is untouched" \
  || bad "the old copy is untouched"
if run --check; then ok "stocked --check exits 0"; else bad "stocked --check exits 0"; fi

# 4. --refresh replaces it with the current build.
printf 'newer build\n' >"$PHONE_PROXY_APK"
if run --refresh; then ok "--refresh exits 0"; else bad "--refresh exits 0" "$(cat "$LOG/out")"; fi
grep -qx 'newer build' "$PHONE_APK_CACHE/phone-link-proxy.apk" && ok "--refresh replaces the copy" \
  || bad "--refresh replaces the copy" "$(cat "$PHONE_APK_CACHE/phone-link-proxy.apk" 2>&1)"

# 5. Activation runs without HOME: the ambulance box is still found.
if run_no_home --check; then ok "works without HOME"; else bad "works without HOME" "$(cat "$LOG/out")"; fi
grep -q 'unbound variable' "$LOG/out" && bad "works without HOME: no unbound variable" \
  || ok "works without HOME: no unbound variable"

# 5a. A named APK that is not there is named, not substituted.
rm -f "$PHONE_APK_CACHE"/*.apk
if PHONE_PROXY_APK=$TMP/gone.apk run; then
  bad "a missing named APK exits 1"
else
  ok "a missing named APK exits 1"
fi
grep -q "not a file: $TMP/gone.apk" "$LOG/out" && ok "names the file it wanted" \
  || bad "names the file it wanted" "$(cat "$LOG/out")"

# 6. --help.
if run --help; then ok "--help exits 0"; else bad "--help exits 0"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
