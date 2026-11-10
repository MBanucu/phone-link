#!/usr/bin/env bash
# Live end-to-end test of the doctor's self-repair:
#
#   1. require the setup to be healthy, with USB tether up (the AP goes down),
#   2. stock the ambulance APK so no download is needed once the AP is gone,
#   3. drop the laptop AP,
#   4. uninstall the proxy app,
#   5. require phone-doctor to flag ap_address, proxy_app and proxy_request,
#   6. run phone-doctor-fix --yes --required (AP + phone link are fixed last),
#   7. require a clean doctor, the AP back up and the phone joined again.
#
#   sudo tests/live/doctor-fix-proxy.sh
#
# Destructive by design: the app's data is lost, and the AP is dropped until
# the fixer restores it. Needs the phone, root, F-Droid access while stocking
# the cache, and USB tether so the proxy can answer while the AP is down.
# Deliberately not named *.test.sh, so `nix flake check` never runs it.
set -u

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN=$ROOT/bin
export PATH="$BIN:$PATH"
. "$ROOT/lib/phone-net.sh"

doctor=${PHONE_DOCTOR:-$BIN/phone-doctor}
fixer=${PHONE_DOCTOR_FIX:-$BIN/phone-doctor-fix}
ap_if=${PHONE_AP_IF:-wlp110s0}

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

TMP=$(mktemp -d)

installed() {
  adb -s "$serial" shell pm path "$PHONE_PROXY_PKG" 2>/dev/null | grep -q '^package:'
}

ap_up() {
  ip -4 -br addr show "$ap_if" 2>/dev/null | grep -qE ' [0-9]+\.[0-9]+'
}

restore() {
  local left apk
  if ! installed; then
    apk=$(phone_apk_cached 2>/dev/null || true)
    printf 'restoring the proxy app from %s\n' "${apk:-F-Droid}" >&2
    if [ -n "$apk" ]; then
      "$BIN/phone-proxy-install" "$apk" >&2 || printf 'restore install failed\n' >&2
    else
      "$BIN/phone-proxy-install" --fdroid >&2 || printf 'restore install failed\n' >&2
    fi
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
}
trap 'restore; rm -rf "$TMP"' EXIT

step "preconditions"
if "$BIN/phone-fix-apk"; then
  ok "ambulance APK is stocked"
else
  bad "cannot stock the ambulance APK"
  exit 2
fi
apk=$(phone_apk_cached) || {
  bad "no cached APK after stocking"
  exit 2
}
export PHONE_PROXY_APK=$apk
printf 'offline APK for the repair: %s\n' "$PHONE_PROXY_APK" >&2

problems=$("$doctor" --analyze 2>/dev/null || true)
if printf '%s\n' "$problems" | grep -q '^fail '; then
  bad "the setup already has required failures; fix it first"
  printf '%s\n' "$problems" >&2
  exit 1
fi
ok "doctor reports no required failures"
if installed; then
  ok "proxy app is installed"
else
  bad "proxy app is not installed; install it before this test"
  exit 1
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
  ok "proxy app is installed again"
else
  bad "proxy app is still missing"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
