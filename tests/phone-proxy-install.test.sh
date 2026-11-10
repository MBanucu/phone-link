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
  install | install-multiple) printf 'Performing Streamed Install\nSuccess\n' ;;
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

# curl stub: the F-Droid v1 API answers with two versions, and every other call
# is treated as a download into whatever -o names.
cat > "$WORK/stub/curl" <<'CURL'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$LOG/curl.log"
case "$*" in
  *api/v1*)
    printf '{"packageName":"com.tokyoxpa3.androidproxy","suggestedVersionCode":24,"packages":[{"versionName":"1.7.4","versionCode":24},{"versionName":"1.7.3","versionCode":23}]}'
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

run() {
  HOME="$WORK/home" PATH="$WORK/stub:$PATH" PHONE_APK_DIR="$WORK/cache" \
    bash "$SCRIPT" "$@" 2>&1
}

run_absent() {
  HOME="$WORK/home" PATH="$WORK/stub:$PATH" PHONE_APK_DIR="$WORK/cache" \
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

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
