#!/usr/bin/env bash
# Live end-to-end test of the doctor's self-repair, against the test build:
#
#   1. require a route that outlives the AP drop, this checkout's test APK and a
#      healthy setup, with USB tether up,
#   2. park that APK in the ambulance box, so the repair needs no network,
#   3. drop the laptop AP,
#   4. uninstall the test app (`org.phonelink.proxy.test`),
#   5. require phone-doctor to flag ap_address, proxy_app and proxy_request,
#   6. run phone-doctor-fix --yes --required: it installs the test build from
#      the parked file (AP + phone link are fixed last),
#   7. require a clean doctor, the test app at this tree's version, the AP back
#      up, the phone joined again — and the daily app exactly as it was.
#
#   sudo tests/live/doctor-fix-proxy.sh
#
# It runs as the test package (`org.phonelink.proxy.test`, port 18080) so a run
# never costs the phone the proxies the daily build has saved. Destructive all
# the same: the test app's data is lost, and the AP is dropped until the fixer
# restores it. Needs the phone, root, the APK from `nix develop .#android -c
# ./android/build.sh` (or PHONE_PROXY_APK=/path), a USB tether so the proxy can
# answer while the AP is down, and an adb route that is not on the AP — dropping
# it cuts every adb call on that address. Nothing is downloaded: the repair
# installs the file this tree built. Deliberately not named *.test.sh, so
# `nix flake check` never runs it.
set -u

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN=$ROOT/bin
export PATH="$BIN:$PATH"
. "$ROOT/lib/phone-net.sh"

doctor=${PHONE_DOCTOR:-$BIN/phone-doctor}
fixer=${PHONE_DOCTOR_FIX:-$BIN/phone-doctor-fix}
ap_if=${PHONE_AP_IF:-wlp110s0}

# The test build, so breaking the setup costs the phone nothing: the daily app
# keeps its saved proxies, its listener and its port. The fixer installs the APK
# that belongs to this package (`phone.app_apk()`), so "reinstall the app"
# means the test one. `lib/phone-net.sh` has already filled in the daily package
# by the time this runs, so the value is set, not defaulted — PHONE_LIVE_PKG
# names another package for a like-for-like run, and the daily one is refused.
daily_pkg=${PHONE_DAILY_PKG:-org.phonelink.proxy}
live_pkg=${PHONE_LIVE_PKG:-org.phonelink.proxy.test}
if [ "$live_pkg" = "$daily_pkg" ]; then
  printf 'refusing to break the daily app: this harness runs %s\n' \
    org.phonelink.proxy.test >&2
  exit 2
fi
export PHONE_PROXY_PKG=$live_pkg
# A spare port: the daily proxy has its own, and two listeners cannot share one.
export PHONE_PROXY_PORT=${PHONE_LIVE_PORT:-18080}

pass=0
fail=0
ok() {
  pass=$((pass + 1))
  printf 'PASS %s\n' "$*"
}
bad() {
  fail=$((fail + 1))
  printf 'FAIL %s\n' "$*"
}
step() { printf '\n== %s\n' "$*"; }

if [ "$(id -u)" -ne 0 ]; then
  printf 'run this with sudo: it reads %s and changes the AP\n' "$PHONE_SECRETS" >&2
  exit 2
fi
[ -x "$doctor" ] || {
  printf 'phone-doctor not found at %s\n' "$doctor" >&2
  exit 2
}
[ -x "$fixer" ] || {
  printf 'phone-doctor-fix not found at %s\n' "$fixer" >&2
  exit 2
}

serial=$(phone_serial) || {
  printf 'no phone attached (see adb devices)\n' >&2
  exit 2
}
export PHONE_SERIAL="$serial"

# The app the repair installs is the one this checkout builds for the package
# under test: `android/build.sh` writes both, and the test package comes from the
# test build. PHONE_PROXY_APK names another file to put through the same test.
case $PHONE_PROXY_PKG in
  org.phonelink.proxy.test) built=$ROOT/android/build/phone-link-proxy-test.apk ;;
  *) built=$ROOT/android/build/phone-link-proxy.apk ;;
esac
APP_APK=${PHONE_PROXY_APK:-$built}

TMP=$(mktemp -d)

installed() {
  adb -s "$serial" shell pm path "$PHONE_PROXY_PKG" 2>/dev/null | grep -q '^package:'
}

ap_up() {
  ip -4 -br addr show "$ap_if" 2>/dev/null | grep -qE ' [0-9]+\.[0-9]+'
}

# Whether this adb transport survives the AP going down. A bare serial is a
# cable; a host:port one is on a network, and if that network is the AP this
# test drops, every adb call from here on is addressed to nothing — including
# the ones that would put things back.
route_survives() {
  local address
  case $serial in
    *:*) address=${serial%:*} ;;
    *) return 0 ;;
  esac
  case $address in
    "${PHONE_AP_SUBNET%.0/24}."*) return 1 ;;
  esac
  return 0
}

# The daily app's own line, so the end of the run can require it untouched.
daily_state() {
  adb -s "$serial" shell dumpsys activity service "$daily_pkg/.ProxyService" 2>/dev/null \
    | tr -d '\r' | grep -m1 '^ *state ' | sed 's/^ *//'
}

daily_path() {
  adb -s "$serial" shell pm path "$daily_pkg" 2>/dev/null | tr -d '\r' | head -1
}

restore() {
  local left
  if ! installed; then
    printf 'restoring the proxy app from %s\n' "$APP_APK" >&2
    "$BIN/phone-proxy-install" "$APP_APK" >&2 \
      || printf 'restore install failed\n' >&2
  fi
  if ! ap_up; then
    printf 'restoring the AP\n' >&2
    "$BIN/phone-ap-up" >&2 || printf 'restore AP failed\n' >&2
  fi
  left=$("$doctor" --analyze 2>/dev/null || true)
  if printf '%s\n' "$left" | grep -q '^fail phone_address '; then
    printf 'rejoining the phone to the AP\n' >&2
    "$BIN/phone-wifi-connect" >&2 || printf 'restore phone link failed\n' >&2
  fi
  left=$("$doctor" --analyze 2>/dev/null || true)
  if printf '%s\n' "$left" | grep -q '^fail proxy_request '; then
    printf 'restoring the proxy settings and start\n' >&2
    "$BIN/phone-proxy-setup" >&2 || printf 'restore setup failed\n' >&2
  fi
  # The test app is a fixture, not a service: leave nothing of it listening.
  if [ "$(daily_state)" != "" ] && installed; then
    "$BIN/phone-proxy-stop" >/dev/null 2>&1 || true
  fi
}
trap 'restore; rm -rf "$TMP"' EXIT

step "preconditions"
# Before anything is dropped: this run has to be able to reach the phone
# afterwards, or it cuts its own link and cannot put anything back.
if route_survives; then
  ok "the adb route is not on the AP ($serial)"
else
  bad "the adb route is on the AP this test drops ($serial)"
  printf '  plug the cable (adb over USB), or run phone-adb-wifi so the phone\n' >&2
  printf '  is reachable another way; the drop cuts every call to %s\n' \
    "${serial%:*}" >&2
  exit 2
fi

if [ -f "$APP_APK" ]; then
  ok "this checkout's app APK is here ($APP_APK)"
else
  bad "no app APK at $APP_APK"
  if [ -n "${PHONE_PROXY_APK:-}" ]; then
    printf 'PHONE_PROXY_APK has to name a file\n' >&2
  else
    printf 'build it first: nix develop .#android -c ./android/build.sh\n' >&2
  fi
  exit 2
fi
# Parked in the ambulance box before the phone is touched, so the repair has a
# local file to install; --refresh replaces a stale copy rather than trusting it.
if "$BIN/phone-fix-apk" --refresh; then
  ok "the ambulance box took the build"
else
  bad "cannot park the app APK in the ambulance box"
  exit 2
fi
parked=$PHONE_APK_CACHE/$(basename "$APP_APK")
if cmp -s "$APP_APK" "$parked"; then
  ok "the parked APK is byte for byte the build"
else
  bad "the parked APK is not the build ($parked)"
fi
# The repair reads PHONE_PROXY_APK first, so it installs exactly this file.
export PHONE_PROXY_APK=$APP_APK
printf 'APK for the repair: %s\n' "$PHONE_PROXY_APK" >&2

# The test app has to exist to be broken on purpose; a stop of it costs nothing.
if installed; then
  ok "the test app is installed ($PHONE_PROXY_PKG)"
else
  if "$BIN/phone-proxy-install" "$APP_APK"; then
    ok "installed the test app"
  else
    bad "cannot install the test app"
    exit 1
  fi
fi
# The battery allowlist is kept per package, so the test app needs its own entry
# before it can count as a healthy setup.
"$BIN/phone-proxy-boot" >&2 || printf 'adding the test app to the allowlist failed\n' >&2
problems=$("$doctor" --analyze 2>/dev/null || true)
if printf '%s\n' "$problems" | grep -q '^fail proxy_request '; then
  # A fresh install (or one an earlier run stopped) has no listener: set the
  # test app up on the spare port so the run starts from a healthy setup.
  "$BIN/phone-proxy-setup" --port "$PHONE_PROXY_PORT" >&2 \
    || printf 'setup of the test app failed\n' >&2
  problems=$("$doctor" --analyze 2>/dev/null || true)
fi
if printf '%s\n' "$problems" | grep -q '^fail '; then
  bad "the test app already has required failures; fix it first"
  printf '%s\n' "$problems" >&2
  exit 1
fi
ok "doctor reports no required failures (for $PHONE_PROXY_PKG)"
daily_before=$(daily_state)
daily_apk_before=$(daily_path)
daily_port=$(printf '%s\n' "$daily_before" | sed -n 's/.*listening on [0-9.]*:\([0-9][0-9]*\).*/\1/p')
if [ -n "$daily_before" ]; then
  ok "the daily app is listening before the run ($daily_before)"
else
  ok "the daily app is not running; nothing to preserve"
fi
tether=$(adb -s "$serial" shell ip -4 -o addr show rndis0 2>/dev/null \
  | tr -d '\r' | awk '{print $4}' | head -1)
if [ -n "$tether" ]; then
  ok "USB tether is up ($tether)"
else
  bad "USB tether must be up: the proxy has to answer while the AP is down"
  exit 1
fi

step "drop the laptop AP"
if nmcli connection down "$PHONE_AP_CON" >/dev/null 2>&1; then
  ok "nmcli connection down $PHONE_AP_CON"
else
  bad "could not drop $PHONE_AP_CON"
  exit 1
fi
tries=0
while [ $tries -lt 10 ]; do
  ap_up || break
  sleep 1
  tries=$((tries + 1))
done
if ap_up; then
  bad "the AP still has an address"
  exit 1
fi
ok "AP is down"
problems=$("$doctor" --analyze 2>/dev/null || true)
if printf '%s\n' "$problems" | grep -q '^fail ap_address '; then
  ok "doctor names ap_address"
else
  bad "doctor does not name ap_address"
  printf '%s\n' "$problems" >&2
fi

step "uninstall the proxy app"
if "$BIN/phone-proxy-uninstall" --yes; then
  ok "phone-proxy-uninstall exited 0"
else
  bad "phone-proxy-uninstall failed"
  exit 1
fi
if installed; then
  bad "the app is still installed after uninstall"
  exit 1
fi
ok "proxy app is gone"

step "doctor sees the broken setup"
if "$doctor" --analyze >"$TMP/problems" 2>&1; then
  bad "doctor still exits 0 with the proxy app missing"
else
  ok "doctor exits 1 with the proxy app missing"
fi
for id in ap_address proxy_app proxy_request; do
  if grep -q "^fail $id " "$TMP/problems"; then
    ok "doctor names $id"
  else
    bad "doctor does not name $id"
  fi
done

step "phone-doctor-fix repairs it (AP and phone link last)"
if "$fixer" --yes --required; then
  ok "phone-doctor-fix exited 0"
else
  bad "phone-doctor-fix exited non-zero"
fi

step "the AP and the phone are back"
if ap_up; then
  ok "AP has an address again"
else
  bad "AP is still down"
fi
if phone_ips 2>/dev/null | grep -Fxq "$PHONE_AP_IP"; then
  ok "phone rejoined the AP ($PHONE_AP_IP)"
else
  bad "phone did not rejoin the AP"
fi
if "$doctor" >"$TMP/doctor" 2>&1; then
  ok "doctor exits 0"
else
  bad "doctor still exits non-zero"
  cat "$TMP/doctor" >&2
fi
problems=$("$doctor" --analyze 2>/dev/null || true)
if printf '%s\n' "$problems" | grep -q '^fail '; then
  bad "required problems remain after the fix"
  printf '%s\n' "$problems" >&2
else
  ok "no required failures remain"
fi
if installed; then
  ok "the test app is installed again"
else
  bad "the test app is still missing"
fi
# The doctor's own verdict, printed as "ok  proxy version  <v> (<code>), this
# checkout's build": the app on the phone is the build that was just installed.
if grep -qE "^ok +proxy version +.*this checkout's build" "$TMP/doctor"; then
  ok "the test app on the phone is this checkout's build"
else
  bad "the phone is not running this checkout's build"
  grep 'proxy version' "$TMP/doctor" >&2 || true
fi
# The point of running as the test package: the app the phone lives on was never
# uninstalled, so its saved proxies are still there. Its listener is a different
# matter — dropping the AP takes the network it listens on with it, so it is
# started again and has to come back on the port it had.
daily_apk_after=$(daily_path)
if [ -n "$daily_apk_after" ] && [ "$daily_apk_after" = "$daily_apk_before" ]; then
  ok "the daily app was never uninstalled ($daily_apk_after)"
else
  bad "the daily app's install changed" "${daily_apk_before:-gone} -> ${daily_apk_after:-gone}"
fi
if [ -n "$daily_port" ]; then
  PHONE_PROXY_PKG=$daily_pkg "$BIN/phone-proxy-setup" --port "$daily_port" >&2 \
    || printf 'restarting the daily proxy failed\n' >&2
  daily_after=$(daily_state)
  case $daily_after in
    *"listening on 0.0.0.0:$daily_port"*)
      ok "the daily app is back on port $daily_port" ;;
    *) bad "the daily app is not back on port $daily_port" "${daily_after:-stopped}" ;;
  esac
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
