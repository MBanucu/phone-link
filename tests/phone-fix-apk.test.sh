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

# A stub curl: two releases, each with the same app version under its own tag,
# and a checksum that matches the bytes the download branch writes. Offline and
# a wrong checksum are the two failures worth testing.
cat >"$STUBS/curl" <<'CURL'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$LOG/curl.log"
[ "${CURL_STUB_OFFLINE:-0}" = 1 ] && exit 22
case "$*" in
  *per_page*)
    printf '%s' '[{"tag_name":"v0.5.0","assets":[{"browser_download_url":"https://example.invalid/releases/download/v0.5.0/phone-link-proxy-0.1.0.apk"}]},{"tag_name":"v0.4.0","assets":[{"browser_download_url":"https://example.invalid/releases/download/v0.4.0/phone-link-proxy-0.1.0.apk"}]}]'
    ;;
  *.sha256)
    if [ "${CURL_STUB_BAD_SUM:-0}" = 1 ]; then
      printf '%s  phone-link-proxy-0.1.0.apk\n' "0000000000000000000000000000000000000000000000000000000000000000"
    else
      printf '%s  phone-link-proxy-0.1.0.apk\n' "$(printf 'apkbytes' | sha256sum | cut -d' ' -f1)"
    fi
    ;;
  *)
    out=""
    prev=""
    for a in "$@"; do
      [ "$prev" = "-o" ] && out=$a
      prev=$a
    done
    [ -n "$out" ] && printf 'apkbytes' >"$out"
    ;;
esac
exit 0
CURL
chmod 755 "$STUBS/curl"
sed -i "1s|.*|#!${BASH_BIN}|" "$STUBS/curl"

run() {
  PATH="$STUBS:$PATH" "$BASH_BIN" "$SCRIPT" "$@" >"$LOG/out" 2>&1
}

run_no_home() {
  env -u HOME -u XDG_CACHE_HOME PATH="$STUBS:$PATH" \
    "$BASH_BIN" "$SCRIPT" "$@" >"$LOG/out" 2>&1
}

run_env() {
  local setting=$1
  shift
  env "$setting" PATH="$STUBS:$PATH" "$BASH_BIN" "$SCRIPT" "$@" >"$LOG/out" 2>&1
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

# 7. The repair kit: --releases keeps the APKs of the newest releases, each
#    named after its tag (two releases can carry the same app version), and
#    each checked against the checksum beside it.
rm -f "$PHONE_APK_CACHE"/*.apk
: >"$LOG/curl.log"
if run --releases; then ok "--releases exits 0"; else bad "--releases exits 0" "$(cat "$LOG/out")"; fi
for tag in v0.5.0 v0.4.0; do
  if [ -f "$PHONE_APK_CACHE/$tag-phone-link-proxy-0.1.0.apk" ]; then
    ok "keeps $tag under its tag"
  else
    bad "keeps $tag under its tag" "$(ls "$PHONE_APK_CACHE" 2>&1)"
  fi
done
grep -q 'repair kit: 2 release APK(s)' "$LOG/out" && ok "counts the kit" \
  || bad "counts the kit" "$(cat "$LOG/out")"

# 8. A second --releases downloads nothing: the box is already the kit.
: >"$LOG/curl.log"
run --releases
downloads=$(grep -c 'releases/download/' "$LOG/curl.log" || true)
[ "$downloads" = 0 ] && ok "a second --releases downloads nothing" \
  || bad "a second --releases downloads nothing" "$downloads downloads"

# 9. A download that does not match its checksum is not kept.
rm -f "$PHONE_APK_CACHE"/v0*.apk
if run_env CURL_STUB_BAD_SUM=1 --releases; then
  ok "a bad checksum does not fail the run"
else
  bad "a bad checksum does not fail the run" "$(cat "$LOG/out")"
fi
grep -q 'does not match its checksum' "$LOG/out" && ok "a bad checksum is named" \
  || bad "a bad checksum is named" "$(cat "$LOG/out")"
if [ -e "$PHONE_APK_CACHE/v0.5.0-phone-link-proxy-0.1.0.apk" ]; then
  bad "a bad checksum is not kept"
else
  ok "a bad checksum is not kept"
fi

# 10. Offline: the build is still kept, the kit is a warning.
rm -rf "$PHONE_APK_CACHE"
if run_env CURL_STUB_OFFLINE=1 --refresh; then ok "offline --refresh exits 0" \
  else bad "offline --refresh exits 0" "$(cat "$LOG/out")"; fi
grep -q 'cannot read the releases' "$LOG/out" && ok "offline says the kit is missing" \
  || bad "offline says the kit is missing" "$(cat "$LOG/out")"
grep -qx 'newer build' "$PHONE_APK_CACHE/phone-link-proxy.apk" && ok "offline still keeps the build" \
  || bad "offline still keeps the build"

# 11. --check lists the box and downloads nothing.
: >"$LOG/curl.log"
if run --check; then ok "--check lists a stocked box" \
  else bad "--check lists a stocked box" "$(cat "$LOG/out")"; fi
grep -q 'ambulance APKs: 1' "$LOG/out" && ok "--check counts what is there" \
  || bad "--check counts what is there" "$(cat "$LOG/out")"
[ -s "$LOG/curl.log" ] && bad "--check downloads nothing" "$(cat "$LOG/curl.log")" \
  || ok "--check downloads nothing"

# 12. --releases takes a count, and refuses anything else.
rm -f "$PHONE_APK_CACHE"/*.apk
run --releases 1
[ -f "$PHONE_APK_CACHE/v0.5.0-phone-link-proxy-0.1.0.apk" ] \
  && ok "--releases 1 keeps the newest" || bad "--releases 1 keeps the newest" "$(ls "$PHONE_APK_CACHE" 2>&1)"
if [ -e "$PHONE_APK_CACHE/v0.4.0-phone-link-proxy-0.1.0.apk" ]; then
  bad "--releases 1 stops at one"
else
  ok "--releases 1 stops at one"
fi
if run --releases two; then bad "a word after --releases is rejected"; else ok "a word after --releases is rejected"; fi

# 6. --help.
if run --help; then ok "--help exits 0"; else bad "--help exits 0"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
