#!/usr/bin/env bash
# Hermetic tests for bin/phone-proxy-uninstall.
#
# The adb stub keeps a marker file for "the app is installed", so uninstall can
# be observed to change state, and nothing touches a real phone.
#
#   bash tests/phone-proxy-uninstall.test.sh
#   SCRIPT=/path/to/phone-proxy-uninstall bash tests/phone-proxy-uninstall.test.sh
set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd -- "$here/.." && pwd)
SCRIPT=${SCRIPT:-$here/../bin/phone-proxy-uninstall}
[ -f "$SCRIPT" ] || {
  echo "no script at $SCRIPT" >&2
  exit 2
}

. "$ROOT/tests/lib/harness.sh"
suite WORK --log . --stubs stub --home home

# adb stub: pm path answers only while the marker file exists; uninstall removes
# it and prints Success.
stub adb
answer adb <<'ADB'
printf '%s\n' "$*" >> "$LOG/adb.log"
[ "${1:-}" = "devices" ] && { printf 'List of devices attached\nTESTPHONE\tdevice\n\n'; exit 0; }
[ "${1:-}" = "-s" ] && shift 2
case "${1:-}" in
  uninstall)
    printf 'Success\n'
    rm -f "$LOG/installed"
    ;;
  shell)
    case "$*" in
      *"cmd package uninstall"*)
        printf 'Success\n'
        rm -f "$LOG/installed"
        ;;
      *"pm path"*) [ -f "$LOG/installed" ] && printf 'package:/data/app/x/base.apk\r\n' ;;
      *dumpsys*) printf '        versionName=1.7.4\r\n' ;;
    esac
    ;;
esac
exit 0
ADB

run() {
  bash "$SCRIPT" "$@" 2>&1
}

# Every case starts from "installed" with an empty call log.
installed() {
  : > "$LOG/installed"
  : > "$LOG/adb.log"
}

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

installed
out=$(run --check)
rc=$?
[ "$rc" = 0 ] && ok "--check exits 0" || bad "--check exits 0" "exit $rc"
case $out in
  *"would run: adb -s TESTPHONE uninstall org.phonelink.proxy"*)
    ok "--check shows the uninstall command"
    ;;
  *) bad "--check shows the uninstall command" "$out" ;;
esac
if grep -q ' uninstall ' "$LOG/adb.log"; then
  bad "--check does not uninstall" "$(grep uninstall "$LOG/adb.log" | tail -1)"
else
  ok "--check does not uninstall"
fi

installed
installed
out=$(run 2>&1)
rc=$?
[ "$rc" = 1 ] && ok "non-interactive run without --yes fails" \
  || bad "non-interactive run without --yes fails" "exit $rc"
case $out in
  *"without --yes"*) ok "failure explains the --yes requirement" ;;
  *) bad "failure explains the --yes requirement" "$out" ;;
esac

installed
expect_exit "--yes uninstalls" 0 --yes
if grep -q -- "-s TESTPHONE uninstall org.phonelink.proxy" "$LOG/adb.log"; then
  ok "uninstall argv is -s SERIAL uninstall PKG"
else
  bad "uninstall argv is -s SERIAL uninstall PKG" "$(grep uninstall "$LOG/adb.log" | tail -1)"
fi
if [ -f "$LOG/installed" ]; then
  bad "state changed: app is gone" "marker still present"
else
  ok "state changed: app is gone"
fi

installed
expect_exit "--keep-data --yes keeps data" 0 --keep-data --yes
if grep -q -- "-s TESTPHONE shell cmd package uninstall -k org.phonelink.proxy" "$LOG/adb.log"; then
  ok "keep-data argv is -s SERIAL shell cmd package uninstall -k PKG"
else
  bad "keep-data argv is -s SERIAL shell cmd package uninstall -k PKG" "$(grep -i uninstall "$LOG/adb.log" | tail -1)"
fi

# The vendored app is still removable by naming it.
installed
if PHONE_PROXY_PKG=com.tokyoxpa3.androidproxy run --yes >/dev/null 2>&1; then
  ok "the vendored app is still removable"
else
  bad "the vendored app is still removable"
fi
grep -q -- "-s TESTPHONE uninstall com.tokyoxpa3.androidproxy" "$LOG/adb.log" \
  && ok "names the vendored package" || bad "names the vendored package"

# Idempotent: when the app is absent the script succeeds and does nothing.
: > "$LOG/adb.log"
rm -f "$LOG/installed"
out=$(run --yes)
rc=$?
[ "$rc" = 0 ] && ok "absent app exits 0" || bad "absent app exits 0" "exit $rc"
case $out in
  *"not installed, nothing to do"*) ok "absent app says so" ;;
  *) bad "absent app says so" "$out" ;;
esac
grep -q ' uninstall ' "$LOG/adb.log" && bad "absent app runs no uninstall" || ok "absent app runs no uninstall"

installed
expect_exit "unknown argument is rejected" 1 --bogus
expect_exit "--help exits 0" 0 --help

finish
