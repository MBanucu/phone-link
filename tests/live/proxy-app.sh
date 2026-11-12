#!/usr/bin/env bash
# Live end-to-end test of the proxy app on the phone:
#
#   0. unlock the phone if the project's own phone-unlock can: the shade
#      ignores tile clicks and nothing can read the panel while the keyguard
#      is up (a phone that stays locked skips those steps),
#   1. install the APK built by android/build.sh and open its panel,
#   2. require auto_start to reach the service and show up in the panel,
#   3. require the panel to say what wireless debugging is doing,
#   4. start it on a spare port with throwaway credentials,
#   5. require a request through the tunnel to answer 200,
#   6. require a wrong password to be refused,
#   7. require the panel's "Listen without authentication" checkbox to drop
#      the password on Start and unticking it to demand one again (both go
#      through Reset, so the form matches the running service first),
#   8. require an unrelated SSID to keep the port closed with the service up,
#   9. require any_network=true to bypass the predicate,
#  10. stop it,
#  11. start and stop it from the Quick Settings tile, which needs the phone
#      unlocked: the shade ignores clicks on a locked screen, so that step is
#      skipped there,
#  12. uninstall (KEEP_APP=1 keeps it installed).
#
#   tests/live/proxy-app.sh
#
# Not named *.test.sh: it needs a phone, a JDK, the Android SDK and installs a
# package, so `nix flake check` must not run it. The vendored proxy is left
# alone: this uses its own port and package.
set -u

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
APK=${PROXY_APP_APK:-$ROOT/android/build/phone-link-proxy.apk}
PORT=${PROXY_APP_PORT:-18080}
PKG=org.phonelink.proxy
SERVICE=$PKG/.ProxyService
START=org.phonelink.proxy.action.START
STOP=org.phonelink.proxy.action.STOP
USER_NAME=phonelink-test
PASSWORD=phonelink-test-password

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

serial=${PHONE_SERIAL:-}
if [ -z "$serial" ]; then
  serial=$(adb devices | awk '$2 == "device" { print $1; exit }')
fi
if [ -z "$serial" ]; then
  printf 'no phone attached (see adb devices)\n' >&2
  exit 2
fi
if [ ! -f "$APK" ]; then
  printf 'no APK at %s\nbuild it first: nix develop .#android -c ./android/build.sh\n' "$APK" >&2
  exit 2
fi

phone() { adb -s "$serial" "$@"; }
shell() { phone shell "$@"; }

# Set when this run woke the phone, so it can be put back to sleep.
unlocked=0

cleanup() {
  shell am start-foreground-service -n "$SERVICE" -a "$STOP" >/dev/null 2>&1
  shell cmd statusbar collapse >/dev/null 2>&1
  sleep 1
  if [ "$unlocked" = 1 ]; then
    shell input keyevent KEYCODE_SLEEP >/dev/null 2>&1
  fi
  if [ -z "${KEEP_APP:-}" ]; then
    phone uninstall "$PKG" >/dev/null 2>&1
  fi
}
trap cleanup EXIT

start_app() {
  shell am start-foreground-service -n "$SERVICE" -a "$START" \
    --ei port "$PORT" --es user "$USER_NAME" --es password "$PASSWORD" "$@" \
    >/dev/null 2>&1
}

foreground() { shell dumpsys activity services "$PKG" | grep -q 'isForeground=true'; }

# The panel has to inflate and stay up; a crash shows in the crash buffer.
panel_opens() {
  shell am start -W -n "$PKG/.MainActivity" >/dev/null 2>&1 || return 1
  sleep 1
  shell dumpsys activity activities | grep -q "$PKG/.MainActivity" || return 1
  ! phone logcat -d -b crash 2>/dev/null | grep -q "$PKG"
}

# The panel's auto_start checkbox reflects what the service stored.
panel_auto_start_checked() {
  shell uiautomator dump /sdcard/proxy-app-ui.xml >/dev/null 2>&1 || return 1
  shell cat /sdcard/proxy-app-ui.xml | grep -q 'id/auto_start"[^/]*checked="true"'
}

# The panel is taller than the screen, and uiautomator only reports what is on
# it, so every control is found by scrolling. Drags start on the right edge,
# outside the edit fields, so the ScrollView owns the gesture.
ui_dump() {
  shell uiautomator dump /sdcard/proxy-app-ui.xml >/dev/null 2>&1 || return 1
  shell cat /sdcard/proxy-app-ui.xml | tr -d '\r'
}

ui_text() { # ui_text ID -> the node's text
  ui_dump | tr '>' '\n' | grep "id/$1\"" | head -1 |
    sed -n 's/.*text="\([^"]*\)".*/\1/p'
}

ui_bounds() { # ui_bounds ID -> "x y" of the node's centre
  ui_dump | tr '>' '\n' | grep "id/$1\"" | head -1 |
    sed -n 's/.*bounds="\[\([0-9]*\),\([0-9]*\)\]\[\([0-9]*\),\([0-9]*\)\]".*/\1 \2 \3 \4/p' |
    awk '{ if (NF == 4) print int(($1 + $3) / 2), int(($2 + $4) / 2) }'
}

panel_top() {
  for _ in 1 2 3 4; do shell input swipe 1390 700 1390 2200 150; done
  sleep 1
}

ui_text_seek() { # ui_text_seek ID, scrolling down until the line is on screen
  local id=$1 value
  panel_top
  for _ in 1 2 3 4 5 6; do
    value=$(ui_text "$id")
    if [ -n "$value" ]; then
      printf '%s\n' "$value"
      return 0
    fi
    shell input swipe 1390 2200 1390 700 200
    sleep 1
  done
  return 1
}

panel_tap() { # panel_tap ID, scrolling down until the control is on screen
  local id=$1 x y
  panel_top
  for _ in 1 2 3 4 5 6; do
    x=""
    y=""
    read -r x y <<EOF
$(ui_bounds "$id")
EOF
    if [ -n "$x" ]; then
      shell input tap "$x" "$y"
      sleep 1
      return 0
    fi
    shell input swipe 1390 2200 1390 700 200
    sleep 1
  done
  return 1
}

# Tile clicks are ignored while the keyguard is up, and uiautomator cannot
# dump a sleeping panel, so unlock through the project's own command. It reads
# the root-only secrets, so a run without sudo leaves the phone locked and the
# steps that need it say so instead of failing.
keyguard_showing() {
  shell dumpsys window policy | grep -q 'showing=true'
}

unlock_phone() {
  keyguard_showing || return 0
  if PHONE_SERIAL="$serial" sudo -n -E "$ROOT/bin/phone-unlock" >/dev/null 2>&1; then
    if keyguard_showing; then
      return 1
    fi
    unlocked=1
    return 0
  fi
  return 1
}

wait_foreground() {
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    foreground && return 0
    sleep 0.5
  done
  return 1
}

# Succeeds when a request through the tunnel reaches the internet.
through_proxy() {
  local code
  code=$(curl -sS -m 15 -o /dev/null -w '%{http_code}' \
    --socks5-hostname "$USER_NAME:$PASSWORD@$ADDRESS:$PORT" https://example.com 2>/dev/null) \
    || return 1
  [ "$code" = "200" ]
}

# Succeeds when the port refuses connections.
port_closed() {
  local status
  curl -sS -m 5 -o /dev/null --socks5-hostname "$USER_NAME:$PASSWORD@$ADDRESS:$PORT" \
    https://example.com >/dev/null 2>&1
  status=$?
  [ "$status" -eq 7 ]
}

ADDRESS=$(shell ip -4 addr show wlan0 2>/dev/null |
  awk '/inet / { sub(/\/.*/, "", $2); print $2; exit }')
SSID=$(shell cmd wifi status 2>/dev/null |
  sed -n 's/^Wifi is connected to "\(.*\)"$/\1/p' | head -1)
if [ -z "$ADDRESS" ] || [ -z "$SSID" ]; then
  printf 'the phone needs a Wi-Fi client link for this harness (address=%s ssid=%s)\n' \
    "${ADDRESS:-none}" "${SSID:-none}" >&2
  exit 2
fi
printf 'phone %s on "%s" at %s, port %s\n' "$serial" "$SSID" "$ADDRESS" "$PORT"

step 'unlock'
if unlock_phone; then
  ok 'the phone is unlocked'
else
  printf 'SKIP unlocking: needs the root-only PIN (sudo -n %s/bin/phone-unlock)\n' "$ROOT"
fi

step 'install'
if phone install -r -g "$APK" >/dev/null 2>&1; then
  ok 'installs'
else
  bad 'installs'
  printf '\n%d passed, %d failed\n' "$pass" "$fail"
  exit 1
fi


step 'panel'
# Only a crash from this run should fail the step, and the buffer can still
# hold one from before.
phone logcat -b crash -c >/dev/null 2>&1
if panel_opens; then ok 'the panel opens'; else bad 'the panel opens'; fi

step 'auto start'
start_app --es ssid "$SSID" --ez any_network false --ez auto_start true
if wait_foreground; then
  ok 'auto_start starts the service'
else
  bad 'auto_start starts the service'
  shell dumpsys activity services "$PKG" | head -3
  phone logcat -d -s phone-link-proxy | tail -5
fi
shell am start -W -n "$PKG/.MainActivity" >/dev/null 2>&1
sleep 1
if panel_auto_start_checked; then ok 'the panel shows auto_start on'; else
  bad 'the panel shows auto_start on'
fi

step 'panel state'
shell am start -W -n "$PKG/.MainActivity" >/dev/null 2>&1
sleep 1
state=$(ui_text_seek adb_state)
case $state in
  'Wireless debugging: on'*|'Wireless debugging: off'*|\
  'Wireless debugging: this build cannot change it'*)
    ok 'the panel says what wireless debugging is doing' ;;
  *)
    bad 'the panel says what wireless debugging is doing' "$state" ;;
esac

step 'allowed network'
start_app --es ssid "$SSID" --ez any_network false
if wait_foreground; then ok 'service is foreground'; else bad 'service is foreground'; fi
if through_proxy; then ok 'request through the tunnel'; else bad 'request through the tunnel'; fi
if curl -sS -m 10 -o /dev/null --socks5-hostname \
  "$USER_NAME:wrong@$ADDRESS:$PORT" https://example.com >/dev/null 2>&1; then
  bad 'a wrong password is refused'
else
  ok 'a wrong password is refused'
fi

step 'anonymous from the panel'
# Reset first: the adb-driven steps above changed what the service runs with,
# while the panel still holds the values it was created with.
if panel_tap reset && panel_tap anonymous && panel_tap start; then
  sleep 3
  if curl -sS -m 10 -o /dev/null --socks5-hostname "$ADDRESS:$PORT" \
    https://example.com >/dev/null 2>&1; then
    ok 'the anonymous checkbox is applied by Start'
  else
    bad 'the anonymous checkbox is applied by Start'
  fi
  # Put authentication back through the same controls: the tunnel works with
  # credentials again, and nobody without them does.
  panel_tap anonymous
  panel_tap start
  sleep 3
  if through_proxy; then
    ok 'unticking it asks for a password again'
  else
    bad 'unticking it asks for a password again'
  fi
  if curl -sS -m 10 -o /dev/null --socks5-hostname "$ADDRESS:$PORT" \
    https://example.com >/dev/null 2>&1; then
    bad 'without the checkbox a password is required'
  else
    ok 'without the checkbox a password is required'
  fi
else
  bad 'the panel controls are reachable'
fi

step 'unrelated SSID'
start_app --es ssid "not-$SSID" --ez any_network false
sleep 2
if port_closed; then ok 'the port is closed'; else bad 'the port is closed'; fi
if foreground; then ok 'the service keeps running while paused'; else
  bad 'the service keeps running while paused'
fi

step 'predicate bypass'
start_app --es ssid "not-$SSID" --ez any_network true
sleep 2
if through_proxy; then ok 'any_network serves requests'; else bad 'any_network serves requests'; fi

step 'stop'
shell am start-foreground-service -n "$SERVICE" -a "$STOP" >/dev/null 2>&1
sleep 2
if foreground; then bad 'stop leaves no service'; else ok 'stop leaves no service'; fi
if port_closed; then ok 'the port is closed after stop'; else bad 'the port is closed after stop'; fi

step 'tile'
if unlock_phone; then :; fi
if keyguard_showing; then
  printf 'SKIP the tile: the shade ignores clicks while the phone is locked\n'
else
  # The tile starts whatever the last start stored, so store the good settings
  # first and stop the service the adb start created.
  start_app --es ssid "$SSID" --ez any_network false
  sleep 1
  shell am start-foreground-service -n "$SERVICE" -a "$STOP" >/dev/null 2>&1
  sleep 2
  shell cmd statusbar add-tile "$PKG/.ProxyTile" >/dev/null 2>&1
  shell cmd statusbar expand-settings >/dev/null 2>&1
  sleep 2
  shell cmd statusbar click-tile "$PKG/.ProxyTile" >/dev/null 2>&1
  if wait_foreground; then ok 'the tile starts the service'; else
    bad 'the tile starts the service'
  fi
  if through_proxy; then ok 'the tile start serves requests'; else
    bad 'the tile start serves requests'
  fi
  shell cmd statusbar expand-settings >/dev/null 2>&1
  sleep 2
  shell cmd statusbar click-tile "$PKG/.ProxyTile" >/dev/null 2>&1
  sleep 3
  if foreground; then bad 'the tile stops the service'; else
    ok 'the tile stops the service'
  fi
  if port_closed; then ok 'the tile stop closes the port'; else
    bad 'the tile stop closes the port'
  fi
  shell cmd statusbar collapse >/dev/null 2>&1
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
