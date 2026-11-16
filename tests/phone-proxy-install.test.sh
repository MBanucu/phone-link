#!/usr/bin/env bash
# Hermetic tests for bin/phone-proxy-install.
#
# A stub `adb` and `curl` sit first on PATH and the F-Droid cache lives in a
# temp dir, so the suite needs no phone, no network and no root.  It asserts the
# contract the NixOS setup relies on: which version is fetched, that the cache
# is keyed by versionCode, that --check never installs, and the exact adb argv.
#
#   bash tests/phone-proxy-install.test.sh
#   SCRIPT=/path/to/phone-proxy-install bash tests/phone-proxy-install.test.sh
set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SCRIPT=${SCRIPT:-$here/../bin/phone-proxy-install}
[ -f "$SCRIPT" ] || {
  echo "no script at $SCRIPT" >&2
  exit 2
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export LOG="$WORK"
mkdir -p "$WORK/stub" "$WORK/cache" "$WORK/home"

# adb stub: one device, a successful install, a version, and a pull that
# writes something.  ADB_STUB_ABSENT simulates a phone without the app.
cat > "$WORK/stub/adb" <<'ADB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$LOG/adb.log"
[ "${1:-}" = "devices" ] && { printf 'List of devices attached\nTESTPHONE\tdevice\n\n'; exit 0; }
[ "${1:-}" = "-s" ] && shift 2
case "${1:-}" in
  install | install-multiple)
    if [ "${ADB_STUB_BAD_SIG:-0}" = 1 ]; then
      printf 'Performing Streamed Install\nFailure [INSTALL_FAILED_UPDATE_INCOMPATIBLE: Package org.phonelink.proxy signatures do not match previously installed version; ignoring!]\n'
      exit 1
    fi
    printf 'Performing Streamed Install\nSuccess\n'
    ;;
  uninstall) printf 'Success\n' ;;
  shell)
    case "$*" in
      *"pm path"*) [ "${ADB_STUB_ABSENT:-0}" = 1 ] || printf 'package:/data/app/x/base.apk\r\n' ;;
      *dumpsys*) [ "${ADB_STUB_ABSENT:-0}" = 1 ] || printf '        versionName=1.7.4\r\n' ;;
    esac
    ;;
  pull)
    mkdir -p "${3:-.}"
    printf 'apkbytes' > "${3:-.}/$(basename "${2:-base.apk}")"
    ;;
esac
exit 0
ADB

# curl stub: the F-Droid v1 API answers with two versions, the GitHub release API
# with one APK and its checksum, and every other call is a download into
# whatever -o names. CURL_STUB_BAD_SUM serves a checksum for other bytes.
cat > "$WORK/stub/curl" <<'CURL'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$LOG/curl.log"
release=http://example.invalid/releases/download/v0.5.0
case "$*" in
  *api/v1*)
    printf '{"packageName":"com.tokyoxpa3.androidproxy","suggestedVersionCode":24,"packages":[{"versionName":"1.7.4","versionCode":24},{"versionName":"1.7.3","versionCode":23}]}'
    ;;
  *releases/latest* | *releases/tags/*)
    printf '{"tag_name":"v0.5.0","assets":[{"name":"phone-link-proxy-0.1.0.apk","browser_download_url":"%s/phone-link-proxy-0.1.0.apk"},{"name":"phone-link-proxy-0.1.0.apk.sha256","browser_download_url":"%s/phone-link-proxy-0.1.0.apk.sha256"}]}' "$release" "$release"
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
    [ -n "$out" ] && printf 'apkbytes' > "$out"
    ;;
esac
exit 0
CURL
chmod 755 "$WORK/stub/adb" "$WORK/stub/curl"

# Build sandboxes have no /usr/bin/env, so point the stubs at this bash.
for stub in "$WORK/stub/adb" "$WORK/stub/curl"; do
  sed -i "1s|.*|#!${BASH}|" "$stub"
done

# --fdroid is for the vendored app, which is the one a store still has; the
# default package is this checkout's own build.
run() {
  HOME="$WORK/home" PATH="$WORK/stub:$PATH" PHONE_APK_DIR="$WORK/cache" \
    PHONE_PROXY_PKG=com.tokyoxpa3.androidproxy bash "$SCRIPT" "$@" 2>&1
}

run_absent() {
  HOME="$WORK/home" PATH="$WORK/stub:$PATH" PHONE_APK_DIR="$WORK/cache" \
    PHONE_PROXY_PKG=com.tokyoxpa3.androidproxy \
    ADB_STUB_ABSENT=1 bash "$SCRIPT" "$@" 2>&1
}

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }

expect_exit() {
  local name=$1 want=$2 out rc
  shift 2
  out=$(run "$@")
  rc=$?
  if [ "$rc" = "$want" ]; then
    ok "$name"
  else
    bad "$name" "exit $rc != $want: $(printf '%s' "$out" | tail -1)"
  fi
}

cache="$WORK/cache/com.tokyoxpa3.androidproxy-1.7.4-24.apk"

expect_exit "fresh --fdroid --check exits 0" 0 --fdroid --check
if [ -f "$cache" ]; then
  ok "cache file keyed by version and versionCode"
else
  bad "cache file keyed by version and versionCode" "$(ls "$WORK/cache" 2>/dev/null)"
fi
if grep -q ' install ' "$WORK/adb.log"; then
  bad "--check never installs" "$(grep install "$WORK/adb.log" | tail -1)"
else
  ok "--check never installs"
fi

downloads_before=$(grep -c 'repo/' "$WORK/curl.log" || true)
expect_exit "cached --fdroid --check exits 0" 0 --fdroid --check
downloads_after=$(grep -c 'repo/' "$WORK/curl.log" || true)
if [ "$downloads_before" = "$downloads_after" ]; then
  ok "second run reuses the cache"
else
  bad "second run reuses the cache" "$downloads_before -> $downloads_after downloads"
fi

expect_exit "--fdroid installs" 0 --fdroid
if grep -q -- "-s TESTPHONE install -r -g $cache" "$WORK/adb.log"; then
  ok "install argv is -s SERIAL install -r -g FILE"
else
  bad "install argv is -s SERIAL install -r -g FILE" "$(grep install "$WORK/adb.log" | tail -1)"
fi

out=$(run --status)
rc=$?
[ "$rc" = 0 ] && ok "--status exits 0" || bad "--status exits 0" "exit $rc"
case $out in
  *"version 1.7.4"*) ok "--status reports 1.7.4" ;;
  *) bad "--status reports 1.7.4" "$out" ;;
esac

out=$(run_absent --status)
rc=$?
[ "$rc" = 1 ] && ok "--status exits 1 when the app is absent" \
  || bad "--status exits 1 when the app is absent" "exit $rc"
case $out in
  *"not installed"*) ok "absent --status says so" ;;
  *) bad "absent --status says so" "$out" ;;
esac

expect_exit "--fdroid --status is rejected" 1 --fdroid --status
expect_exit "--fdroid with a path is rejected" 1 --fdroid /tmp/whatever.apk
expect_exit "--pull --fdroid is rejected" 1 --pull --fdroid
expect_exit "unknown option is rejected" 1 --bogus

expect_exit "--pull writes the backup" 0 --pull "$WORK/pull"
if [ -f "$WORK/pull/com.tokyoxpa3.androidproxy-1.7.4.apk" ]; then
  ok "pull backup named <pkg>-<version>.apk"
else
  bad "pull backup named <pkg>-<version>.apk" "$(ls "$WORK/pull" 2>/dev/null)"
fi

printf 'apkbytes' > "$WORK/local.apk"
: > "$WORK/adb.log"
expect_exit "--check with an explicit APK exits 0" 0 --check "$WORK/local.apk"
if grep -q ' install ' "$WORK/adb.log"; then
  bad "--check with an APK never installs" "$(grep install "$WORK/adb.log" | tail -1)"
else
  ok "--check with an APK never installs"
fi

run_own() {
  HOME="$WORK/home" PATH="$WORK/stub:$PATH" PHONE_APK_DIR="$WORK/cache" \
    PHONE_PROXY_PKG=org.phonelink.proxy bash "$SCRIPT" "$@" 2>&1
}

# 20. This repository's own app is granted the one permission that lets it turn
#     wireless debugging back on; the vendored proxy is not.
: > "$WORK/adb.log"
run_own "$WORK/local.apk" >/dev/null
if grep -q 'shell pm grant org.phonelink.proxy android.permission.WRITE_SECURE_SETTINGS' \
    "$WORK/adb.log"; then
  ok "our APK is granted WRITE_SECURE_SETTINGS"
else
  bad "our APK is granted WRITE_SECURE_SETTINGS" "$(cat "$WORK/adb.log")"
fi
: > "$WORK/adb.log"
run "$WORK/local.apk" >/dev/null
if grep -q 'pm grant' "$WORK/adb.log"; then
  bad "the vendored proxy is granted nothing" "$(grep grant "$WORK/adb.log")"
else
  ok "the vendored proxy is granted nothing"
fi

# 24. --release takes the APK a release of this repository carries, checks the
#     .sha256 beside it, and installs that file.
release_run() {
  HOME="$WORK/home" PATH="$WORK/stub:$PATH" PHONE_APK_DIR="$WORK/cache" \
    PHONE_PROXY_PKG=org.phonelink.proxy PHONE_LINK_REPO=example/phone-link \
    bash "$SCRIPT" "$@" 2>&1
}
release_cache="$WORK/cache/phone-link-proxy-0.1.0.apk"
rm -f "$release_cache"
: > "$WORK/adb.log"
out=$(release_run --release --check)
rc=$?
[ "$rc" = 0 ] && ok "--release --check exits 0" || bad "--release --check exits 0" "exit $rc: $out"
if [ -f "$release_cache" ]; then
  ok "--release caches the asset under its release name"
else
  bad "--release caches the asset under its release name" "$(ls "$WORK/cache")"
fi
case $out in
  *"checksum:"*"matches the release"*) ok "--release checks the .sha256" ;;
  *) bad "--release checks the .sha256" "$out" ;;
esac
if grep -q ' install ' "$WORK/adb.log"; then
  bad "--release --check never installs" "$(grep install "$WORK/adb.log" | tail -1)"
else
  ok "--release --check never installs"
fi

rm -f "$release_cache"
: > "$WORK/adb.log"
release_run --release >/dev/null
if grep -q -- "-s TESTPHONE install -r -g $release_cache" "$WORK/adb.log"; then
  ok "--release installs the release APK"
else
  bad "--release installs the release APK" "$(grep install "$WORK/adb.log" | tail -1)"
fi

: > "$WORK/adb.log"
out=$(release_run --release v0.5.0 --check)
case $out in
  *"release: v0.5.0"*) ok "--release TAG names the tag" ;;
  *) bad "--release TAG names the tag" "$out" ;;
esac

# 27. A download that does not match the release is not installed.
rm -f "$release_cache"
: > "$WORK/adb.log"
out=$(CURL_STUB_BAD_SUM=1 HOME="$WORK/home" PATH="$WORK/stub:$PATH" \
  PHONE_APK_DIR="$WORK/cache" PHONE_PROXY_PKG=org.phonelink.proxy \
  PHONE_LINK_REPO=example/phone-link bash "$SCRIPT" --release 2>&1)
rc=$?
[ "$rc" = 1 ] && ok "a bad checksum exits 1" || bad "a bad checksum exits 1" "exit $rc"
case $out in
  *"checksum mismatch"*) ok "a bad checksum says so" ;;
  *) bad "a bad checksum says so" "$out" ;;
esac
if grep -q ' install ' "$WORK/adb.log"; then
  bad "a bad checksum installs nothing" "$(grep install "$WORK/adb.log" | tail -1)"
else
  ok "a bad checksum installs nothing"
fi

# 28. adb refusing because the keys differ is named, and --replace-signer is
#     what gets past it: the old app goes first, so the install can land.
: > "$WORK/adb.log"
out=$(ADB_STUB_BAD_SIG=1 HOME="$WORK/home" PATH="$WORK/stub:$PATH" \
  PHONE_APK_DIR="$WORK/cache" PHONE_PROXY_PKG=org.phonelink.proxy \
  bash "$SCRIPT" "$WORK/local.apk" 2>&1)
rc=$?
[ "$rc" = 1 ] && ok "a signature mismatch exits 1" || bad "a signature mismatch exits 1" "exit $rc"
case $out in
  *"signed with a different key"*"--replace-signer"*) ok "a signature mismatch names --replace-signer" ;;
  *) bad "a signature mismatch names --replace-signer" "$out" ;;
esac

: > "$WORK/adb.log"
out=$(HOME="$WORK/home" PATH="$WORK/stub:$PATH" PHONE_APK_DIR="$WORK/cache" \
  PHONE_PROXY_PKG=org.phonelink.proxy bash "$SCRIPT" --replace-signer "$WORK/local.apk" 2>&1)
rc=$?
[ "$rc" = 1 ] && ok "--replace-signer without --yes refuses" \
  || bad "--replace-signer without --yes refuses" "exit $rc: $out"
if grep -q 'uninstall' "$WORK/adb.log"; then
  bad "a refused replacement uninstalls nothing" "$(cat "$WORK/adb.log")"
else
  ok "a refused replacement uninstalls nothing"
fi

: > "$WORK/adb.log"
release_run --replace-signer --yes "$WORK/local.apk" >/dev/null
uninstall_line=$(grep -n 'uninstall org.phonelink.proxy' "$WORK/adb.log" | head -1 | cut -d: -f1)
install_line=$(grep -n ' install -r -g' "$WORK/adb.log" | head -1 | cut -d: -f1)
if [ -n "$uninstall_line" ] && [ -n "$install_line" ] && [ "$uninstall_line" -lt "$install_line" ]; then
  ok "--replace-signer uninstalls before installing"
else
  bad "--replace-signer uninstalls before installing" "$(cat "$WORK/adb.log")"
fi

expect_exit "--release --status is rejected" 1 --release --status
expect_exit "--fdroid --release is rejected" 1 --fdroid --release
expect_exit "--release with two tags is rejected" 1 --release v0.5.0 v0.4.0
expect_exit "--replace-signer --check is rejected" 1 --replace-signer --check "$WORK/local.apk"

build_out=$(run --build --release 2>&1) && bad "--build with --release exits 1" \
  || ok "--build with --release exits 1"
printf '%s' "$build_out" | grep -q 'drop the path and the other sources' \
  && ok "--build says what to drop" || bad "--build says what to drop" "$build_out"
if run --build --check >/dev/null 2>&1; then bad "--build with --check exits 1"; else
  ok "--build with --check exits 1"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
