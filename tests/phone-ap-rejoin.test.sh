#!/usr/bin/env bash
# Hermetic tests for lib/phone-ap-rejoin.sh: stub iw, adb and sleep, and drive
# the station/AP/USB state through files. No phone, no radio, no root.
set -u

BASH_BIN=$(command -v bash)
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/lib/phone-ap-rejoin.sh

. "$ROOT/tests/lib/harness.sh"
tmpdir TMP
export LOG=$TMP/log STUBS=$TMP/bin
mkdir -p "$LOG" "$STUBS" "$TMP/run/phone-link"

PSK=psk-do-not-leak-42
SSID=PhoneLink

stub_cmd iw "$STUBS" <<'EOF'
printf '%s\n' "$*" >>"$LOG/iw_calls"
case "$*" in
  "dev "*" station dump")
    case "$(cat "$LOG/iw_state" 2>/dev/null)" in
      down) exit 1 ;;
      station) printf 'Station aa:bb:cc:dd:ee:ff (on wlp110s0)\n\tsignal: -50 dBm\n' ;;
      *) printf 'Interface wlp110s0\n' ;;
    esac
    ;;
  "dev "*" link")
    case "$(cat "$LOG/link_state" 2>/dev/null)" in
      connected) printf 'Connected to aa:bb:cc:dd:ee:ff (on wlp110s0)\n\tSSID: PhoneLink\n' ;;
      *) printf 'Not connected.\n' ;;
    esac
    ;;
esac
EOF

stub_cmd adb "$STUBS" <<'EOF'
printf '%s\n' "$*" >>"$LOG/adb_calls"
case "$*" in
  "-d get-state")
    [ -e "$LOG/usb" ] || exit 1
    printf 'device\n'
    ;;
  "-d shell ip -4 -o addr show")
    cat "$LOG/phone_ip" 2>/dev/null
    ;;
  "-d shell cmd wifi connect-network "*)
    printf '%s\n' "$*" >>"$LOG/connect"
    if [ -e "$LOG/connect_helps" ]; then
      if [ "${PHONE_AP_ROLE:-local}" = external ]; then
        printf '2: wlan0    inet %s/24 brd 192.168.77.255 scope global wlan0\n' \
          "${PHONE_PROXY_HOST:-192.168.77.232}" >"$LOG/phone_ip"
      else
        printf 'station\n' >"$LOG/iw_state"
      fi
    fi
    ;;
  "-d shell svc wifi disable") printf 'disable\n' >>"$LOG/fallback" ;;
  "-d shell svc wifi enable")
    printf 'enable\n' >>"$LOG/fallback"
    if [ -e "$LOG/fallback_helps" ]; then
      if [ "${PHONE_AP_ROLE:-local}" = external ]; then
        printf '2: wlan0    inet %s/24 brd 192.168.77.255 scope global wlan0\n' \
          "${PHONE_PROXY_HOST:-192.168.77.232}" >"$LOG/phone_ip"
      else
        printf 'station\n' >"$LOG/iw_state"
      fi
    fi
    ;;
esac
EOF

stub_cmd sleep "$STUBS" <<'EOF'
exit 0
EOF

STATE=$TMP/run/phone-link/ap-rejoin.last
: >"$LOG/output"
export PHONE_AP_IF=wlp110s0
export PHONE_AP_SSID=$SSID
export PHONE_AP_SECURITY=wpa2
export PHONE_AP_PASS=$PSK
export PHONE_AP_REJOIN_STATE=$STATE
export PHONE_AP_REJOIN_INTERVAL=300
export PHONE_AP_REJOIN_WAIT=1
export PHONE_AP_REJOIN_SLEEP=0
export PHONE_AP_IW=$STUBS/iw
export PHONE_AP_ADB=$STUBS/adb
export PHONE_AP_SLEEP=$STUBS/sleep

run() {
  "$BASH_BIN" "$SCRIPT" >"$LOG/out" 2>"$LOG/err"
  status=$?
  cat "$LOG/out" "$LOG/err" >>"$LOG/output"
  return "$status"
}

reset() {
  : >"$LOG/adb_calls"
  : >"$LOG/iw_calls"
  : >"$LOG/connect"
  : >"$LOG/fallback"
  rm -f "$STATE" "$LOG/usb" "$LOG/connect_helps" "$LOG/fallback_helps"
  printf 'empty\n' >"$LOG/iw_state"
  printf 'disconnected\n' >"$LOG/link_state"
  : >"$LOG/phone_ip"
}

connect_count() {
  grep -c 'connect-network' "$LOG/connect" 2>/dev/null || true
}

# 1. The interface is missing or down: no adb call, nothing to throttle.
reset
printf 'down\n' >"$LOG/iw_state"
if run; then ok "a down interface exits 0"; else bad "a down interface exits 0"; fi
[ -s "$LOG/adb_calls" ] && bad "a down interface makes no adb call" \
  || ok "a down interface makes no adb call"
[ -e "$STATE" ] && bad "a down interface writes no state" \
  || ok "a down interface writes no state"

# 2. A station is associated: never touch a working link.
reset
printf 'station\n' >"$LOG/iw_state"
if run; then ok "an associated station exits 0"; else bad "an associated station exits 0"; fi
[ -s "$LOG/adb_calls" ] && bad "an associated station makes no adb call" \
  || ok "an associated station makes no adb call"
[ -e "$STATE" ] && bad "an associated station writes no state" \
  || ok "an associated station writes no state"

# 3. No USB device: the Wi-Fi adb transport is gone with the link, so there is
#    nothing to act through and the throttle window must not be consumed.
reset
if run; then ok "no USB device exits 0"; else bad "no USB device exits 0"; fi
[ "$(connect_count)" = 0 ] && ok "no USB device makes no connect call" \
  || bad "no USB device makes no connect call" "$(cat "$LOG/connect")"
[ -e "$STATE" ] && bad "no USB device writes no state" \
  || ok "no USB device writes no state"

# 4. No station, USB present, connect-network works: one call with the right
#    SSID and key management, then the station appears.
reset
: >"$LOG/usb"
: >"$LOG/connect_helps"
if run; then ok "a successful connect exits 0"; else bad "a successful connect exits 0" "$(cat "$LOG/err")"; fi
[ "$(connect_count)" = 1 ] && ok "connect-network is called exactly once" \
  || bad "connect-network is called exactly once (got $(connect_count))"
grep -qx -- "-d shell cmd wifi connect-network $SSID wpa2 $PSK" "$LOG/connect" \
  && ok "connect-network gets the SSID, wpa2 and the PSK" \
  || bad "connect-network gets the SSID, wpa2 and the PSK" "$(cat "$LOG/connect")"
[ "$(cat "$LOG/iw_state")" = station ] && ok "the station appears after connect" \
  || bad "the station appears after connect"
[ -s "$LOG/fallback" ] && bad "a successful connect does not toggle the radio" \
  || ok "a successful connect does not toggle the radio"
[ -s "$STATE" ] && ok "a successful attempt writes the throttle state" \
  || bad "a successful attempt writes the throttle state"

# 5. connect-network does not help: the radio toggle runs once and the phone
#    comes back through it.
reset
: >"$LOG/usb"
: >"$LOG/fallback_helps"
if run; then ok "the fallback exits 0"; else bad "the fallback exits 0" "$(cat "$LOG/err")"; fi
[ "$(cat "$LOG/fallback" 2>/dev/null)" = "$(printf 'disable\nenable')" ] \
  && ok "the fallback disables and enables Wi-Fi once" \
  || bad "the fallback disables and enables Wi-Fi once" "$(cat "$LOG/fallback")"
[ "$(cat "$LOG/iw_state")" = station ] && ok "the station appears after the fallback" \
  || bad "the station appears after the fallback"

# 5b. Nothing brings the phone back: one short line on stderr, non-zero exit,
#     and the state file still throttles the next tick.
reset
: >"$LOG/usb"
if run; then bad "an absent phone exits non-zero"; else ok "an absent phone exits non-zero"; fi
[ "$(cat "$LOG/fallback" 2>/dev/null)" = "$(printf 'disable\nenable')" ] \
  && ok "the fallback still runs once when it cannot help" \
  || bad "the fallback still runs once when it cannot help" "$(cat "$LOG/fallback")"
[ "$(wc -l <"$LOG/err")" -le 1 ] && ok "the failure prints at most one line" \
  || bad "the failure prints at most one line" "$(cat "$LOG/err")"
[ -s "$STATE" ] && ok "the failed attempt writes the throttle state" \
  || bad "the failed attempt writes the throttle state"

# 6. An immediate second run is inside the throttle window: no adb call, even
#    though the AP still has no station.
: >"$LOG/adb_calls"
printf 'empty\n' >"$LOG/iw_state"
if run; then ok "a throttled run exits 0"; else bad "a throttled run exits 0"; fi
[ -s "$LOG/adb_calls" ] && bad "a throttled run makes no adb call" \
  || ok "a throttled run makes no adb call"

# 6b. External role: the laptop is a client, so the phone's association is
#     asked over USB.  Without the laptop's client link the watchdog stays out.
export PHONE_AP_ROLE=external
export PHONE_PROXY_HOST=192.168.77.232

# Not linked to the external AP: no adb call at all.
reset
: >"$LOG/usb"
if run; then ok "external: an unlinked laptop exits 0"; else
  bad "external: an unlinked laptop exits 0" "$(cat "$LOG/err")"
fi
[ -s "$LOG/adb_calls" ] && bad "external: an unlinked laptop makes no adb call" \
  || ok "external: an unlinked laptop makes no adb call"
[ -e "$STATE" ] && bad "external: an unlinked laptop writes no state" \
  || ok "external: an unlinked laptop writes no state"

# Linked, and the phone already holds its reservation: nothing to do.
reset
: >"$LOG/usb"
printf 'connected\n' >"$LOG/link_state"
printf '2: wlan0    inet 192.168.77.232/24 brd 192.168.77.255 scope global wlan0\n' \
  >"$LOG/phone_ip"
if run; then ok "external: an associated phone exits 0"; else
  bad "external: an associated phone exits 0" "$(cat "$LOG/err")"
fi
[ "$(connect_count)" = 0 ] && ok "external: an associated phone is not nudged" \
  || bad "external: an associated phone is not nudged" "$(cat "$LOG/connect")"
if grep -q 'station dump' "$LOG/iw_calls"; then
  bad "external: no local station dump is consulted"
else
  ok "external: no local station dump is consulted"
fi

# Linked, phone away, USB present: connect-network brings it back and the
# phone's own address list is what confirms it.
reset
: >"$LOG/usb"
printf 'connected\n' >"$LOG/link_state"
: >"$LOG/connect_helps"
if run; then ok "external: connect-network recovers the phone"; else
  bad "external: connect-network recovers the phone" "$(cat "$LOG/err")"
fi
[ "$(connect_count)" = 1 ] && ok "external: connect-network is called once" \
  || bad "external: connect-network is called once (got $(connect_count))"
grep -q 'inet 192.168.77.232/' "$LOG/phone_ip" \
  && ok "external: the phone holds its reservation after the nudge" \
  || bad "external: the phone holds its reservation after the nudge" "$(cat "$LOG/phone_ip")"
[ -s "$STATE" ] && ok "external: the attempt writes the throttle state" \
  || bad "external: the attempt writes the throttle state"

# Linked but no USB: nothing to act through, and the window is not consumed.
reset
printf 'connected\n' >"$LOG/link_state"
if run; then ok "external: no USB exits 0"; else
  bad "external: no USB exits 0" "$(cat "$LOG/err")"
fi
[ "$(connect_count)" = 0 ] && ok "external: no USB makes no connect call" \
  || bad "external: no USB makes no connect call" "$(cat "$LOG/connect")"
[ -e "$STATE" ] && bad "external: no USB writes no state" \
  || ok "external: no USB writes no state"
unset PHONE_AP_ROLE PHONE_PROXY_HOST

# 7. The PSK never reaches stdout or stderr, even when the phone does not come
#    back and the fallback runs.
if grep -qF "$PSK" "$LOG/output"; then
  bad "the PSK never appears on stdout/stderr"
else
  ok "the PSK never appears on stdout/stderr"
fi

finish
