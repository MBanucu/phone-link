#!/usr/bin/env bash
# Hermetic tests for bin/phone-fix-internet: stub curl, adb, nmcli and the
# per-path fix scripts. No network, no phone.
set -u

BASH_BIN=$(command -v bash)
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/bin/phone-fix-internet
. "$ROOT/tests/lib/harness.sh"
suite
# One target for every adb call; the live phone has more than one transport.
export PHONE_SERIAL=TESTPHONE
# The waits being tested are waits for a phone; here the phone is a stub,
# so the polls are as short as the environment allows them to be.
export PHONE_FIX_SETTLE=0


stub curl
answer curl <<'EOF'
if [ "$(cat "$LOG/online")" = 1 ]; then printf '200'; else printf '000'; fi
EOF

stub adb
answer adb <<'EOF'
printf 'adb %s\n' "$*" >>"$LOG/actions"
case "$*" in
  *"cmd wifi start-softap"*)
    [ "${HOTSPOT_WORKS:-0}" = 1 ] && printf '1\n' >"$LOG/online"
    ;;
esac
EOF

stub nmcli
answer nmcli <<'EOF'
printf 'nmcli %s\n' "$*" >>"$LOG/actions"
case "$*" in
  "-t -f NAME con show") cat "$LOG/names" ;;
  "connection up "*) printf '1\n' >"$LOG/online" ;;
esac
EOF

stub phone-fix-mobile-data
answer phone-fix-mobile-data <<'EOF'
printf 'phone-fix-mobile-data\n' >>"$LOG/actions"
[ "${MOBILE_WORKS:-0}" = 1 ] && printf '1\n' >"$LOG/online"
exit 0
EOF

stub phone-usb-tether-default
answer phone-usb-tether-default <<'EOF'
printf 'phone-usb-tether-default\n' >>"$LOG/actions"
[ "${USB_TETHERS:-0}" = 1 ] && printf '1\n' >"$LOG/online"
exit 0
EOF


run() {
  "$BASH_BIN" "$SCRIPT" "$@" >"$LOG/out" 2>&1
}

# 1. Already online: no changes.
printf '1\n' >"$LOG/online"
rm -f "$LOG/actions"
if run; then ok "online exits 0"; else bad "online exits 0" "$(cat "$LOG/out")"; fi
[ -s "$LOG/actions" ] && bad "online changes nothing" || ok "online changes nothing"

# 2. Mobile data restores it first.
printf '0\n' >"$LOG/online"
: >"$LOG/names"
rm -f "$LOG/actions"
MOBILE_WORKS=1 run && ok "mobile data path exits 0" || bad "mobile data path exits 0" "$(cat "$LOG/out")"
grep -qx 'phone-fix-mobile-data' "$LOG/actions" && ok "tries mobile data" \
  || bad "tries mobile data"
grep -q 'internet is up over mobile data' "$LOG/out" && ok "reports the mobile uplink" \
  || bad "reports the mobile uplink"

# 3. USB tethering is the second try.
printf '0\n' >"$LOG/online"
rm -f "$LOG/actions"
USB_TETHERS=1 run && ok "USB tether path exits 0" || bad "USB tether path exits 0" "$(cat "$LOG/out")"
grep -qx 'phone-usb-tether-default' "$LOG/actions" && ok "tries the USB tether" \
  || bad "tries the USB tether"
grep -q 'internet is up over USB tethering' "$LOG/out" && ok "reports the tether uplink" \
  || bad "reports the tether uplink"

# 4. The hotspot is the last try and the laptop joins the saved profile.
printf '0\n' >"$LOG/online"
printf 'XPLORE 2\n' >"$LOG/names"
rm -f "$LOG/actions"
if HOTSPOT_WORKS=1 run; then ok "hotspot path exits 0"; else bad "hotspot path exits 0" "$(cat "$LOG/out")"; fi
grep -q 'cmd wifi start-softap' "$LOG/actions" && ok "starts the hotspot" \
  || bad "starts the hotspot" "$(cat "$LOG/actions" 2>/dev/null)"
grep -qF "shell cmd wifi start-softap 'XPLORE 2'" "$LOG/actions" \
  && ok "quotes the hotspot SSID as one remote argument" \
  || bad "quotes the hotspot SSID as one remote argument" "$(cat "$LOG/actions" 2>/dev/null)"
grep -q -- '-s TESTPHONE shell cmd wifi start-softap' "$LOG/actions" \
  && ok "pins the hotspot command to the chosen serial" \
  || bad "pins the hotspot command to the chosen serial" "$(cat "$LOG/actions" 2>/dev/null)"
grep -q 'connection up XPLORE 2' "$LOG/actions" && ok "joins the saved hotspot" \
  || bad "joins the saved hotspot" "$(cat "$LOG/actions" 2>/dev/null)"
grep -q 'internet is up over the phone hotspot' "$LOG/out" && ok "reports the hotspot uplink" \
  || bad "reports the hotspot uplink" "$(cat "$LOG/out")"

# 5. Nothing works: fail with a manual hint.
printf '0\n' >"$LOG/online"
: >"$LOG/names"
rm -f "$LOG/actions"
if run; then bad "all paths failing exits 1"; else ok "all paths failing exits 1"; fi
grep -q 'could not restore internet' "$LOG/out" && ok "explains the failure" \
  || bad "explains the failure" "$(cat "$LOG/out")"

# 6. --check is read-only.
printf '0\n' >"$LOG/online"
rm -f "$LOG/actions"
if run --check; then bad "offline --check exits 1"; else ok "offline --check exits 1"; fi
[ -s "$LOG/actions" ] && bad "--check changes nothing" || ok "--check changes nothing"

# 7. --help.
if run --help; then ok "--help exits 0"; else bad "--help exits 0"; fi

finish
