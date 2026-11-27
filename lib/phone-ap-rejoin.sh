#!/usr/bin/env bash
# Re-assert the phone's association with the link-only PhoneLink AP.
#
# Android validates the AP as "no internet" (it is deliberately DHCP-only,
# without a router or DNS option, and forwarded traffic is dropped), and after
# a few reports it sets the saved network to NETWORK_SELECTION_TEMPORARY_DISABLED
# with reason NETWORK_SELECTION_DISABLED_NO_INTERNET_TEMPORARY.  That disable is
# temporary (Android documents up to 10 minutes), so after an AP restart the
# phone stays away for up to that window even though it is sitting on the desk,
# then rejoins on its own.  This watchdog makes the recovery immediate when USB
# is available, in seconds instead of minutes; it does not make recovery
# possible at all (issues #33 and #36).  It must not make the AP answer the
# connectivity probe: the AP has to stay unvalidated so the phone keeps using
# cellular.  Instead the association is re-asserted from the laptop.
#
# The timer runs it every 30 s.  It is quiet and bounded: it does nothing at
# all unless the AP is up with no station, does nothing without a USB adb
# device (there is no other transport left exactly when this is needed), and
# acts at most once per PHONE_AP_REJOIN_INTERVAL seconds.  The state file is
# written before adb is touched, so a phone that ignores the command cannot be
# hammered by the next tick.
#
# Values come from the environment so the module binds its own paths and a
# test can run the same script against a temporary tree:
#   PHONE_AP_IF             AP interface (default wlp110s0)
#   PHONE_AP_SSID           SSID the phone must join (default PhoneLink)
#   PHONE_AP_SECURITY       key management for connect-network (default wpa2)
#   PHONE_AP_PASS           PSK; empty skips connect-network (never printed)
#   PHONE_AP_REJOIN_STATE   last-run epoch file (default /run/phone-link/ap-rejoin.last)
#   PHONE_AP_REJOIN_INTERVAL seconds between actions (default 300)
#   PHONE_AP_REJOIN_WAIT    seconds to wait for a station after each action (default 30)
#   PHONE_AP_REJOIN_SLEEP   seconds between station checks (default 3; 0 for tests)
#   PHONE_AP_IW             iw binary (default iw)
#   PHONE_AP_ADB            adb binary (default adb)
#   PHONE_AP_DATE           date binary for epochs (default date)
#   PHONE_AP_SLEEP          sleep binary (default sleep)
set -u

iface=${PHONE_AP_IF:-wlp110s0}
ssid=${PHONE_AP_SSID:-PhoneLink}
security=${PHONE_AP_SECURITY:-wpa2}
psk=${PHONE_AP_PASS:-}
state_file=${PHONE_AP_REJOIN_STATE:-/run/phone-link/ap-rejoin.last}
interval=${PHONE_AP_REJOIN_INTERVAL:-300}
wait_seconds=${PHONE_AP_REJOIN_WAIT:-30}
sleep_seconds=${PHONE_AP_REJOIN_SLEEP:-3}
iw_cmd=${PHONE_AP_IW:-iw}
adb_cmd=${PHONE_AP_ADB:-adb}
date_cmd=${PHONE_AP_DATE:-date}
sleep_cmd=${PHONE_AP_SLEEP:-sleep}

now() {
  "$date_cmd" +%s
}

# One station is enough: the AP is only there for this phone, and acting while
# any client is associated would risk knocking a working link down.
#
# The match is bash-native instead of grep because the unit's PATH only carries
# bash, coreutils, iw, adb and iproute2; a missing grep must not turn the
# watchdog into a silent no-op.  `Station` is the first word of each entry in
# `iw dev <iface> station dump`.
station_present() {
  local out
  out=$("$iw_cmd" dev "$iface" station dump 2>/dev/null) || return 1
  case "$out" in
    Station* | *$'\n'Station*) return 0 ;;
  esac
  return 1
}

# Condition 1: the AP must exist and be up.  `station dump` fails on a missing
# or down interface, and succeeds with no station on a beaconing AP.
if ! dump=$("$iw_cmd" dev "$iface" station dump 2>/dev/null); then
  exit 0
fi

# Condition 2: never touch a phone that is already associated.
case "$dump" in
  Station* | *$'\n'Station*) exit 0 ;;
esac

# Condition 3: the throttle.  A missing or malformed file is "never run"; a
# timestamp in the future (clock stepped back) is also treated as stale so the
# watchdog cannot stay disabled for the length of the jump.
now_epoch=$(now)
last=$(cat "$state_file" 2>/dev/null || true)
case "$last" in
  '' | *[!0-9]*) last=0 ;;
esac
if [ "$last" -gt 0 ] && [ "$last" -le "$now_epoch" ]; then
  if [ $((now_epoch - last)) -lt "$interval" ]; then
    exit 0
  fi
fi

# The Wi-Fi adb transport is gone with the link, so only the USB transport can
# carry the command.  No USB device means the phone is elsewhere: do nothing,
# and do not consume the throttle window.
if ! "$adb_cmd" -d get-state >/dev/null 2>&1; then
  exit 0
fi

# Record the attempt before acting.  If the phone is unresponsive, the next
# 30 s tick sees the fresh timestamp and stays quiet until the window passes.
mkdir -p "$(dirname "$state_file")" 2>/dev/null || true
printf '%s\n' "$now_epoch" >"$state_file" 2>/dev/null || true

wait_for_station() {
  deadline=$(($(now) + wait_seconds))
  while :; do
    if station_present; then
      return 0
    fi
    if [ "$(now)" -ge "$deadline" ]; then
      return 1
    fi
    "$sleep_cmd" "$sleep_seconds"
  done
}

# `cmd wifi connect-network` connects despite the temporary no-internet
# disable and marks the network user-selected, and it does not drop the radio.
# Android may still print TEMPORARY_DISABLED in `dumpsys wifi`; the associated
# station is what matters.  The PSK goes on the adb command line but every byte
# of adb's output is discarded, and no variable is ever expanded into a message.
if [ -n "$psk" ]; then
  "$adb_cmd" -d shell cmd wifi connect-network "$ssid" "$security" "$psk" \
    >/dev/null 2>&1 || true
  if wait_for_station; then
    exit 0
  fi
fi

# The connect command did not bring it back (or there was no PSK to send).
# Toggling the radio is the fallback: it clears a stuck supplicant state, at
# the cost of a short drop.
"$adb_cmd" -d shell svc wifi disable >/dev/null 2>&1 || true
"$sleep_cmd" 2
"$adb_cmd" -d shell svc wifi enable >/dev/null 2>&1 || true

if wait_for_station; then
  exit 0
fi

# One short line at most: the timer retries after the throttle window.
printf '%s\n' "phone-link-ap-rejoin: $ssid did not come back" >&2
exit 1
