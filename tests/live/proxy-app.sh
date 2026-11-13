#!/usr/bin/env bash
# Live end-to-end test of the proxy app on the phone:
#
#   0. unlock the phone if the project's own phone-unlock can: the shade
#      ignores tile clicks and nothing can read the panel while the keyguard
#      is up (a phone that stays locked skips those steps),
#   1. install the APK built by android/build.sh and open its panel,
#   2. require auto_start to reach the service and show up in the panel,
#   2a. take the battery exemption away and require the header's warning mark
#      to appear and to open the battery request, then put the exemption back
#      and require the mark to go away again (skipped when it was never set),
#   3. require the panel to say what wireless debugging is doing,
#   4. start it on a spare port with throwaway credentials,
#   5. require a request through the tunnel to answer 200,
#   6. require a wrong password to be refused,
#   7. require the panel's "Listen without authentication" checkbox to drop
#      the password on Start and unticking it to demand one again (both go
#      through Reset, so the form matches the running service first),
#   8. require an unrelated SSID to keep the port closed with the service up,
#   9. require any_network=true to bypass the predicate,
#  10. save the running configuration with SAVE_PROFILE, require dumpsys and
#      the panel's list to show its card, start it again by name after moving
#      the listener somewhere else (the service switches come back with it),
#      require an unknown name to start nothing, and remove it again with
#      DELETE_PROFILE,
#  10a. open that card, change the port, press the plain Save and require the
#      saved configuration to hold the form — including an auto-start switch
#      that was toggled in the same visit, and create a proxy from the list's
#      New proxy button, which has to save it and open it,
#  10c. save ten proxies and require New proxy to stay reachable under them
#      and to save an eleventh,
#  10b. require the open proxy's own log to show the traffic counters, the
#      events it caused and their port, and Clear to empty the list,
#  11. stop it,
#  12. start and stop it from the Quick Settings tile, which needs the phone
#      unlocked: the shade ignores clicks on a locked screen, so that step is
#      skipped there,
#  13. require every instant the phone wrote down to have a place in the
#      recording: the flashes it paints at the start and the end of the run are
#      fitted to the mp4, and a fit worse than 10 ms fails the run,
#  14. uninstall (KEEP_APP=1 keeps it installed).
#
#   tests/live/proxy-app.sh
#
# Not named *.test.sh: it needs a phone, a JDK, the Android SDK and installs a
# package, so `nix flake check` must not run it. The vendored proxy is left
# alone: this uses its own port and package.
#
# Every run keeps its evidence in result-live/<UTC start>/ (or
# PHONE_LIVE_ARTIFACTS): the phone's screen as an mp4 (frames.sh pulls stills
# out of it), the screen as XML for every capture, every action and every
# capture stamped with the phone's clock (actions.csv, input.csv, ui-index.csv)
# and clock.txt, which maps that clock into the recording, and the timing of each
# step appended to result-live/timings.csv, which is never rewritten — the
# history is what makes "is this cheap enough to run before a commit"
# answerable. PHONE_LIVE_CAPTURE=0 skips the recording and the snapshots.
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
# The capture app: a test-only accessibility service that writes the screen as
# XML in about a tenth of a second, where `adb shell uiautomator dump` costs
# seconds. It is installed for the run and removed afterwards;
# PHONE_LIVE_DUMPS=uiautomator uses the slow path on purpose.
CAPTURE_APK=${PROXY_CAPTURE_APK:-$ROOT/android/build/capture.apk}
CAPTURE_PKG=${PROXY_CAPTURE_PKG:-org.phonelink.capture}
CAPTURE_DIR=/sdcard/Android/data/$CAPTURE_PKG/files
# The flashes that tie the phone's clock to the recording, and the tool that
# fits them: eight edges held 200 ms each, at the start of the run and again
# just before the recorder stops.
FLASH_EDGES=${PHONE_LIVE_FLASH_EDGES:-8}
FLASH_PERIOD=${PHONE_LIVE_FLASH_PERIOD:-200}
CLOCK=${PHONE_LIVE_CLOCK_SH:-$ROOT/tests/live/clock.sh}
capture_dumps=0
capture_old_services=""
capture_old_enabled=""

pass=0
fail=0
# The step being timed, so the CSV gets one row per step, not just the total.
step_name=""
step_start=0
step_pass=0
step_fail=0

ok() {
  pass=$((pass + 1))
  step_pass=$((step_pass + 1))
  printf 'PASS %s\n' "$*"
}
bad() {
  fail=$((fail + 1))
  step_fail=$((step_fail + 1))
  printf 'FAIL %s\n' "$*"
}

# Milliseconds since the epoch, for the per-step timings.
now_ms() { date +%s%3N; }

# Append-only, one row per step plus a TOTAL row: the point of the file is the
# history, so it is never rewritten and never sorted.
timing_row() { # timing_row STEP SECONDS PASSED FAILED STATUS
  if [ ! -f "$TIMINGS" ]; then
    printf 'run,step,seconds,passed,failed,status\n' >"$TIMINGS"
  fi
  printf '%s,%s,%s,%s,%s,%s\n' "$run_id" "$1" "$2" "$3" "$4" "$5" >>"$TIMINGS"
}

flush_step() {
  [ -n "$step_name" ] || return 0
  local seconds
  seconds=$(awk -v start="$step_start" -v end="$(now_ms)" \
    'BEGIN { printf "%.1f", (end - start) / 1000 }')
  timing_row "$step_name" "$seconds" "$step_pass" "$step_fail" \
    "$([ "$step_fail" -eq 0 ] && echo ok || echo failed)"
  step_name=""
  step_pass=0
  step_fail=0
}

step() {
  flush_step
  step_name=$1
  step_start=$(now_ms)
  printf '\n== %s\n' "$*"
}

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

# Where this run's evidence goes, and the one file that outlives it.
run_id=$(date -u +%Y%m%dT%H%M%SZ)
ARTIFACTS=${PHONE_LIVE_ARTIFACTS:-$ROOT/result-live/$run_id}
TIMINGS=${PHONE_LIVE_TIMINGS:-$ROOT/result-live/timings.csv}
mkdir -p "$ARTIFACTS" "$(dirname "$TIMINGS")"
# The actions that had to go through `input`, each with the interval its
# instant is inside; the ones the phone took itself are in the actions.csv the
# capture service writes, which is pulled with the rest of its files.
printf 'start_ns,end_ns,kind,what\n' >"$ARTIFACTS/input.csv"

# Set when this run woke the phone, so it can be put back to sleep.
unlocked=0
# Set when this run changed the screen timeout, so the old one can go back.
screen_timeout=""

# --- the evidence a failed run leaves behind -----------------------------

capturing=0
screenrecord_pid=""
snapshot_pid=""
run_start=$(now_ms)
# How well the phone's clock and the recording agree, from the flashes.
clock_summary=""
clock_fit=""
clock_failed=""

# uiautomator serves one dump at a time; a dump that arrives while another is
# running can fail outright rather than queue, and a failed one costs a step a
# retry, so the snapshots and the steps share this lock. A lock that outlives
# a dozen seconds is treated as left behind by something that died holding it,
# so a run cannot wedge.
dump_lock() {
  local waited=0
  while ! mkdir "$ARTIFACTS/.dump" 2>/dev/null; do
    sleep 0.2
    waited=$((waited + 1))
    if [ "$waited" -ge 60 ]; then
      rmdir "$ARTIFACTS/.dump" 2>/dev/null
      mkdir "$ARTIFACTS/.dump" 2>/dev/null && break
    fi
  done
}

dump_unlock() { rmdir "$ARTIFACTS/.dump" 2>/dev/null || true; }

# The screen as XML as often as uiautomator will serve it, next to an index of
# when each frame was taken. A dump costs about two and a half seconds on this
# phone, so that is the rate: the recording is the record with every frame in
# it, and these are the ones that can be read as text.
ui_snapshots() {
  local index=0
  while [ -f "$ARTIFACTS/.capturing" ]; do
    index=$((index + 1))
    dump_lock
    shell timeout 8 uiautomator dump /sdcard/proxy-app-shot.xml >/dev/null 2>&1
    shell cat /sdcard/proxy-app-shot.xml 2>/dev/null | tr -d '\r' \
      >"$ARTIFACTS/ui-$(printf '%05d' "$index").xml"
    printf '%s,%s,poll\n' "$index" "$(now_ms)" >>"$ARTIFACTS/ui-index.csv"
    dump_unlock
    sleep 0.2
  done
}

# Install the capture app and point the phone's accessibility settings at it,
# remembering what they were so the phone is put back exactly as it was found.
# It is a separate package, so nothing here touches the app under test.
capture_start() {
  [ "$capture_dumps" = 1 ] && return 0
  [ -f "$CAPTURE_APK" ] || return 1
  [ "${PHONE_LIVE_DUMPS:-capture}" = uiautomator ] && return 1
  phone install -r -g "$CAPTURE_APK" >/dev/null 2>&1 || return 1
  capture_old_services=$(shell settings get secure enabled_accessibility_services |
    tr -d '\r')
  capture_old_enabled=$(shell settings get secure accessibility_enabled | tr -d '\r')
  local services="$CAPTURE_PKG/.DumpService"
  case $capture_old_services in
    '' | null) ;;
    *) services="$capture_old_services:$services" ;;
  esac
  shell settings put secure enabled_accessibility_services "$services" >/dev/null 2>&1
  shell settings put secure accessibility_enabled 1 >/dev/null 2>&1
  shell rm -rf "$CAPTURE_DIR" >/dev/null 2>&1
  sleep 3
  # Only believe it when a capture comes back: a service that could not bind
  # looks exactly like one that was never enabled.
  if capture_dump | grep -q '<hierarchy'; then
    capture_dumps=1
    return 0
  fi
  capture_stop
  return 1
}

capture_stop() {
  capture_watch false
  if [ -n "$capture_old_services$capture_old_enabled" ]; then
    shell settings put secure enabled_accessibility_services \
      "$capture_old_services" >/dev/null 2>&1
    shell settings put secure accessibility_enabled "$capture_old_enabled" \
      >/dev/null 2>&1
    capture_old_services=""
    capture_old_enabled=""
  fi
  capture_dumps=0
}

# One capture through the service: the broadcast writes the file before it
# returns, so this is two adb round trips and no waiting.
capture_dump() {
  shell am broadcast -a "$CAPTURE_PKG.DUMP" -n "$CAPTURE_PKG/.DumpReceiver" \
    >/dev/null 2>&1
  shell cat "$CAPTURE_DIR/latest.xml" 2>/dev/null | tr -d '\r'
}

# Automatic captures on or off: one XML per changed screen.
capture_watch() { # capture_watch true|false
  shell am broadcast -a "$CAPTURE_PKG.WATCH" --ez watch "$1" \
    -n "$CAPTURE_PKG/.DumpReceiver" >/dev/null 2>&1
}

# Paint the screen the flash colour, at instants the phone writes down. Where
# those flashes land in screen.mp4 is what says where the phone's clock sits in
# the recording; the broadcast returns at once and the flashes play out.
flash_markers() {
  shell am broadcast -a "$CAPTURE_PKG.FLASH" --ei edges "$FLASH_EDGES" \
    --ei period "$FLASH_PERIOD" -n "$CAPTURE_PKG/.DumpReceiver" >/dev/null 2>&1
}

# --- what the run does on the phone --------------------------------------
# Every touch is taken by the phone rather than sent to it: the service
# dispatches the gesture and writes down the instant it did, on the clock the
# captures use, so an action and the screen it changed sit on one timeline and
# both can be found in the recording. `input tap` is a fresh JVM per call, so
# its instant is only known to within the length of that call.
tap() { # tap X Y
  if [ "$capture_dumps" = 1 ] &&
    shell am broadcast -a "$CAPTURE_PKG.TAP" --ei x "$1" --ei y "$2" \
      -n "$CAPTURE_PKG/.DumpReceiver" >/dev/null 2>&1; then
    return 0
  fi
  input_action tap "$1" "$2"
}

swipe() { # swipe X1 Y1 X2 Y2 MS
  if [ "$capture_dumps" = 1 ] &&
    shell am broadcast -a "$CAPTURE_PKG.SWIPE" --ei x1 "$1" --ei y1 "$2" \
      --ei x2 "$3" --ei y2 "$4" --ei ms "$5" \
      -n "$CAPTURE_PKG/.DumpReceiver" >/dev/null 2>&1; then
    return 0
  fi
  input_action swipe "$1" "$2" "$3" "$4" "$5"
}

back() { # back -> the phone's own Back
  if [ "$capture_dumps" = 1 ] &&
    shell am broadcast -a "$CAPTURE_PKG.BACK" \
      -n "$CAPTURE_PKG/.DumpReceiver" >/dev/null 2>&1; then
    return 0
  fi
  input_action keyevent 4
}

home() {
  if [ "$capture_dumps" = 1 ] &&
    shell am broadcast -a "$CAPTURE_PKG.HOME" \
      -n "$CAPTURE_PKG/.DumpReceiver" >/dev/null 2>&1; then
    return 0
  fi
  input_action keyevent KEYCODE_HOME
}

# What is left to `input` — typing and the odd key — cannot say when it landed:
# it is one JVM that starts a third of a second before it injects anything. The
# phone's clock is read either side of it in the same shell command instead, so
# the record carries the interval the instant is inside.
input_action() { # input_action ARGS...
  local readings
  readings=$(shell "a=\$(cut -d' ' -f1 /proc/uptime)
input $*
b=\$(cut -d' ' -f1 /proc/uptime)
echo \"\$a \$b\"" | tr -d '\r' | awk 'NF == 2 { print $1, $2; exit }')
  case $readings in
    *' '*) ;;
    *) return 0 ;;
  esac
  printf '%s,%s,input,%s\n' \
    "$(awk -v t="${readings% *}" 'BEGIN { printf "%.0f", t * 1e9 }')" \
    "$(awk -v t="${readings#* }" 'BEGIN { printf "%.0f", t * 1e9 }')" \
    "$*" >>"$ARTIFACTS/input.csv"
}

# --- waiting on the phone instead of on the clock -------------------------
# A step used to tap and then sleep: too long when the phone is quick, too short
# when it is busy. The service holds a broadcast until the screen it already
# watches says what the step is waiting for, so the step continues on the event
# it caused — and, because it is the same service, the instant it continued is
# in the run's record too.

# One argument for the phone's shell: a needle is XML, and XML is full of the
# punctuation a shell would eat.
phone_arg() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

wait_phone() { # wait_phone AM-ARGS... -> 0 the screen answered, 1 time ran out
  [ "$capture_dumps" = 1 ] || return 1
  local out
  out=$(shell am broadcast -a "$CAPTURE_PKG.WAIT" "$@" \
    -n "$CAPTURE_PKG/.DumpReceiver" 2>/dev/null)
  case $out in *'result=0'*) return 0 ;; esac
  return 1
}

wait_for() { # wait_for NEEDLE [MS] -> the screen holds it
  wait_phone --es has "$(phone_arg "$1")" --ei timeout "${2:-3000}"
}

wait_gone() { # wait_gone NEEDLE [MS] -> the screen has stopped holding it
  wait_phone --es has "$(phone_arg "$1")" --ez gone true \
    --ei timeout "${2:-3000}"
}

wait_change() { # wait_change [MS] -> the screen said something
  wait_phone --ez change true --ei timeout "${1:-2000}"
}

# The screen has stopped moving: the service answers once nothing on it has
# changed for a moment, which is the event a step actually wants after a tap.
settle() { # settle [QUIET_MS]
  if [ "$capture_dumps" != 1 ]; then
    sleep 1
    return 0
  fi
  wait_phone --ei quiet "${1:-250}" --ei timeout 2500
}

# --- straight lines, run on the phone ------------------------------------
# One broadcast per tap, key and wait is a round trip each — a tenth of a
# second before the phone does anything — which for "type a name, press OK,
# wait for the page" is most of a second. A sequence is that whole straight
# line in one message: the phone runs it on a thread of its own and answers
# when it is over, saying which instruction stopped it. Instructions, matchers
# and the result: android/capture/src/org/phonelink/capture/Sequence.java.
#
# Used where a step is a known line from here to there; anything that depends
# on an answer — a port that serves, a profile in dumpsys — stays on the host.
sequence_stopped=""
sequence() { # sequence 'SCRIPT' -> 0 when every instruction ran
  [ "$capture_dumps" = 1 ] || return 1
  local out
  out=$(shell am broadcast -a "$CAPTURE_PKG.SEQUENCE" --es script "$(phone_arg "$1")" \
    -n "$CAPTURE_PKG/.DumpReceiver" 2>/dev/null)
  case $out in
    *'result=0'*) sequence_stopped=""; return 0 ;;
  esac
  # The instruction that stopped it, for the step's own diagnostics: the
  # record in actions.csv has the same line with its instant.
  sequence_stopped=$(printf '%s' "$out" |
    sed -n 's/.*data="\([^"]*\)".*/\1/p')
  return 1
}

# The panel, up and still, whatever it was showing before.
open_panel() {
  shell am start -W -n "$PKG/.MainActivity" >/dev/null 2>&1
  settle
}

# Where the phone's clock sits in the recording: clock.sh fits the flashes and
# leaves the mapping in $ARTIFACTS/clock.txt, so any device_ns in the run's own
# files can be turned into a second of screen.mp4 afterwards.
calibrate_clock() {
  [ -f "$ARTIFACTS/screen.mp4" ] && [ -f "$ARTIFACTS/clock.csv" ] || return 0
  local summary
  if summary=$(bash "$CLOCK" "$ARTIFACTS" 2>/dev/null); then
    clock_summary=${summary#clock: }
    # What the fit is worth, in milliseconds; the worst single flash is
    # allowed to be half a frame off, that being how often the screen changes.
    clock_fit=$(printf '%s' "$summary" |
      sed -n 's/.*+\/- \([0-9.]*\) ms.*/\1/p')
    printf 'clock: %s\n' "$clock_summary"
    printf '       so a device_ns in ui-index.csv, actions.csv or input.csv is\n'
    printf '       mapped by clock.txt; the flashes are in clock.csv\n'
  else
    clock_failed=1
    printf 'clock: the flashes could not be fitted to the recording\n'
  fi
}

start_capture() {
  [ "${PHONE_LIVE_CAPTURE:-1}" = 0 ] && return 0
  # screenrecord refuses to start with the screen off or a keyguard up, which
  # is why this runs after the unlock step.
  shell rm -f /sdcard/proxy-app.mp4 >/dev/null 2>&1
  screenrecord_pid=$(shell "screenrecord --bit-rate 4000000 --time-limit 1800 \
/sdcard/proxy-app.mp4 >/dev/null 2>&1 & echo \$!")
  screenrecord_pid=$(printf '%s' "$screenrecord_pid" | tr -d '\r\n ')
  if [ "$capture_dumps" = 1 ]; then
    # The service records a screen per change by itself; there is nothing to
    # poll, and its files are pulled when the run ends.
    capture_watch true
    # screenrecord encodes a screen that changes, not a screen that is there:
    # on a still phone the recording has no first frame to hang the clock from,
    # and a flash before that frame would be a flash nothing recorded. The
    # shade opens and closes first — a change, and the only thing on screen at
    # this point in the run — and then the phone paints its clock into it.
    shell cmd statusbar expand-notifications >/dev/null 2>&1
    settle 500
    shell cmd statusbar collapse >/dev/null 2>&1
    settle 500
    flash_markers
  else
    : >"$ARTIFACTS/.capturing"
    ui_snapshots &
    snapshot_pid=$!
  fi
  capturing=1
  printf 'capture: screen.mp4 and ui-*.xml in %s\n' "$ARTIFACTS"
}

stop_capture() {
  [ "$capturing" = 1 ] || return 0
  capturing=0
  if [ -n "$screenrecord_pid" ] && [ "$capture_dumps" = 1 ]; then
    # The last burst ends the run: the recorder only encodes what changes, so
    # its last frame is the screen after the flash that stops just before the
    # kill — which is the end the calibration counts back from.
    flash_markers
    sleep "$(awk -v e="$FLASH_EDGES" -v p="$FLASH_PERIOD" \
      'BEGIN { printf "%.1f", e * p / 1000 + 0.6 }')"
  fi
  if [ "$capture_dumps" = 1 ]; then
    capture_watch false
    phone pull "$CAPTURE_DIR/." "$ARTIFACTS/" >/dev/null 2>&1
    shell rm -rf "$CAPTURE_DIR" >/dev/null 2>&1
    if [ -f "$ARTIFACTS/index.csv" ]; then
      mv -f "$ARTIFACTS/index.csv" "$ARTIFACTS/ui-index.csv"
    fi
    rm -f "$ARTIFACTS/latest.xml"
  fi
  rm -f "$ARTIFACTS/.capturing"
  if [ -n "$snapshot_pid" ]; then
    wait "$snapshot_pid" 2>/dev/null
    snapshot_pid=""
  fi
  if [ -n "$screenrecord_pid" ]; then
    # SIGINT is how screenrecord is asked to finalise the file.
    shell kill -INT "$screenrecord_pid" >/dev/null 2>&1
    sleep 2
    phone pull /sdcard/proxy-app.mp4 "$ARTIFACTS/screen.mp4" >/dev/null 2>&1
    shell rm -f /sdcard/proxy-app.mp4 >/dev/null 2>&1
    screenrecord_pid=""
  fi
  calibrate_clock
}

cleanup() {
  stop_capture
  # Off the phone again: the settings go back to what they were and the test
  # package is uninstalled, so nothing of this run is left behind.
  capture_stop
  phone uninstall "$CAPTURE_PKG" >/dev/null 2>&1
  restore_autofill
  restore_play_protect
  shell am start-foreground-service -n "$SERVICE" -a "$STOP" >/dev/null 2>&1
  shell cmd statusbar collapse >/dev/null 2>&1
  # Whatever this run saved: a crash halfway through must not leave the phone
  # with test proxies in its list.
  local leftover
  for leftover in harness-panel harness-save harness-one harness-new; do
    shell am start-foreground-service -n "$SERVICE" \
      -a org.phonelink.proxy.action.DELETE_PROFILE --es profile "$leftover" \
      >/dev/null 2>&1
  done
  sleep 1
  if [ -n "$screen_timeout" ]; then
    shell settings put system screen_off_timeout "$screen_timeout" >/dev/null 2>&1
  fi
  if [ "$unlocked" = 1 ]; then
    shell input keyevent KEYCODE_SLEEP >/dev/null 2>&1
  fi
  if [ -z "${KEEP_APP:-}" ]; then
    phone uninstall "$PKG" >/dev/null 2>&1
  fi
  flush_step
  # Whether every instant the phone wrote down has a place in the recording.
  if [ -n "$clock_summary" ]; then
    if awk -v fit="${clock_fit:-99}" 'BEGIN { exit !(fit <= 10) }'; then
      ok "the recording and the phone share a clock ($clock_summary)"
    else
      bad "the recording and the phone share a clock ($clock_summary)"
    fi
  elif [ -n "$clock_failed" ]; then
    bad 'the recording and the phone share a clock'
  fi
  local total
  total=$(awk -v start="$run_start" -v end="$(now_ms)" \
    'BEGIN { printf "%.1f", (end - start) / 1000 }')
  timing_row TOTAL "$total" "$pass" "$fail" \
    "$([ "$fail" -eq 0 ] && echo ok || echo failed)"
  printf 'timings: %s\n' "$TIMINGS"
  printf 'artifacts: %s\n' "$ARTIFACTS"
}
# An interrupted run finalises its recording too, or the phone keeps it.
trap cleanup EXIT
trap 'exit 130' INT TERM

start_app() {
  # anonymous is pinned: a configuration a previous run left in the store must
  # not turn the test's listener into an open relay.
  shell am start-foreground-service -n "$SERVICE" -a "$START" \
    --ei port "$PORT" --es user "$USER_NAME" --es password "$PASSWORD" \
    --ez anonymous false "$@" >/dev/null 2>&1
}

# The listener is rebuilt asynchronously after Start, so poll for the state
# instead of sleeping and hoping. "no" also requires that the credentials do
# get through, since a closed port would refuse a bare request as well.
wait_anonymous() { # wait_anonymous yes|no
  local want=$1 free i
  for i in $(seq 15); do
    if curl -sS -m 3 -o /dev/null --socks5-hostname "$ADDRESS:$PORT" \
      https://example.com >/dev/null 2>&1; then
      free=yes
    else
      free=no
    fi
    if [ "$free" = "$want" ]; then
      if [ "$want" = no ] && ! through_proxy; then
        sleep 1
        continue
      fi
      return 0
    fi
    sleep 1
  done
  return 1
}

foreground() { shell dumpsys activity services "$PKG" | grep -q 'isForeground=true'; }

# The panel has to inflate and stay up; a crash shows in the crash buffer.
panel_opens() {
  shell am start -W -n "$PKG/.MainActivity" >/dev/null 2>&1 || return 1
  settle
  shell dumpsys activity activities | grep -q "$PKG/.MainActivity" || return 1
  ! phone logcat -d -b crash 2>/dev/null | grep -q "$PKG"
}

# Whether a checkbox is ticked, scrolling down until it is on screen.
panel_checked() { # panel_checked ID -> yes|no
  local id=$1 node
  panel_top
  for _ in 1 2 3 4 5 6; do
    node=$(ui_dump | tr '>' '\n' | grep "id/$id\"")
    if [ -n "$node" ]; then
      case $node in
        *'checked="true"'*) printf 'yes\n' ;;
        *) printf 'no\n' ;;
      esac
      return 0
    fi
    swipe 1300 2200 1300 1200 200
    settle
  done
  return 1
}

# The profile page is split into segments now, so a control is looked for on
# the segment that holds it rather than by scrolling the whole page.
panel_tab() { # panel_tab listener|service|log
  ui_tap_id "tab_$1"
}

# The panel's auto_start checkbox reflects what the configuration holds.
panel_auto_start_checked() {
  panel_tab service || return 1
  [ "$(panel_checked auto_start)" = yes ]
}

# The panel shows one page at a time behind the menu at the top, and
# uiautomator only reports what is on screen, so a control is looked for after
# switching to its page and, inside a page, by scrolling. Drags start on the
# right edge, outside the edit fields, so the page's ScrollView owns them.
ui_dump() {
  # Two ways this can come back useless: a dump that failed while a window was
  # animating ("could not get idle state"), and a toast, which takes the focus
  # and makes the dump contain only the toast window. Both are waited out: the
  # answer is only accepted when the panel itself is in it.
  local attempt xml recovered=0
  for attempt in 1 2 3 4 5 6 7 8; do
    if [ "$capture_dumps" = 1 ]; then
      # The capture app answers in about a tenth of a second and writes the
      # file before the broadcast returns, so nothing is waited for.
      xml=$(capture_dump)
    else
      # A dump can hang while a window never goes idle, so give it a deadline,
      # and it waits for a snapshot to finish instead of colliding with it.
      dump_lock
      shell timeout 8 uiautomator dump /sdcard/proxy-app-ui.xml >/dev/null 2>&1
      xml=$(shell cat /sdcard/proxy-app-ui.xml 2>/dev/null | tr -d '\r')
      dump_unlock
    fi
    # Accept the panel, or one of the app's own dialogs: the battery request is
    # a window of its own and the dump then holds only that one.
    if printf '%s' "$xml" | grep -q '<hierarchy' &&
      { printf '%s' "$xml" | grep -q "$PKG:id/header_title" ||
        printf '%s' "$xml" | grep -q 'id/alertTitle"' ||
        printf '%s' "$xml" | grep -q 'text="About this app"'; }; then
      printf '%s\n' "$xml"
      return 0
    fi
    # Nothing of the app in the dump means something else has the focus. The
    # app gets one chance to come back first, and only then Back, which is what
    # dismisses a system or password-manager sheet (or the keyboard, a window of
    # its own). Once each per call: a Back per retry walks out of the app and
    # then off its home screen, which is how a whole run ends up on the
    # launcher.
    if ! printf '%s' "$xml" | grep -q "package=\"$PKG\""; then
      case $recovered in
        0)
          shell am start -W -n "$PKG/.MainActivity" >/dev/null 2>&1
          recovered=1
          ;;
        1)
          back >/dev/null 2>&1
          recovered=2
          ;;
      esac
    fi
    # Whatever it was is waited out rather than slept through: a toast or a
    # sheet leaves on its own, and the wait ends on the event that says so.
    wait_change 700 || true
  done
  return 1
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
  # Both ends stay inside the page area: a drag that leaves it belongs to
  # whatever is underneath instead of the page.
  for _ in 1 2 3 4; do swipe 1300 1200 1300 2200 150; done
  settle
}

# A configuration under a name, and the same back off the phone again.
save_profile() {
  shell am start-foreground-service -n "$SERVICE" \
    -a org.phonelink.proxy.action.SAVE_PROFILE --es profile "$1" >/dev/null 2>&1
  sleep 2
}

delete_profile_by_adb() {
  shell am start-foreground-service -n "$SERVICE" \
    -a org.phonelink.proxy.action.DELETE_PROFILE --es profile "$1" >/dev/null 2>&1
  sleep 2
}

# What the phone is showing, for a step that failed to find the panel.
panel_where() {
  printf '  focus: %s\n' "$(shell dumpsys window 2>/dev/null |
    grep -m1 mCurrentFocus | sed 's/^ *//')"
  printf '  activity records: %s\n' "$(shell dumpsys activity activities 2>/dev/null |
    grep -c "$PKG/.MainActivity")"
  printf '  app nodes: %s\n' "$(ui_dump | grep -o "$PKG:id/[a-z_]*" | wc -l)"
  if [ -n "$sequence_stopped" ]; then
    printf '  last sequence stopped at: %s\n' "$sequence_stopped"
  fi
}

# Start can open the battery request when auto-start promises a restart the
# phone will not deliver; it is a window of its own and would swallow the taps
# of the next step, so answer it and carry on.
dismiss_battery() {
  # One message: wait a moment for the request, answer it if it came, and wait
  # for the dialog to be gone. If it did not come the sequence stops at its
  # first instruction after that moment, which is the cost of asking — and
  # that is no failure of the step that called this.
  sequence 'wait contains="Let the proxy restart by itself" 700; tap-id button2 1000; wait-gone id=button2 2000'
  return 0
}

# The one button on a proxy's own page starts it, and stops it while it runs.
panel_toggle() {
  panel_tap toggle || return 1
  dismiss_battery
}

# The menu is a popup over the header, opened by the burger, and picking an
# item is a straight line: the burger, then the item once it has stopped
# sliding — a tap at where a sliding item was a moment ago lands on whatever
# moved into its place, which the phone checks for by looking twice.
menu_pick() { # menu_pick TEXT
  sequence "tap-id menu 3000; tap-text \"$1\" 3000; wait-quiet 250"
}

# One card's node, found by the name in the same card: the list is a column of
# them and a dump is flat, so the scan walks cards until a name matches.
card_line() { # card_line NAME ID -> the node's line, or nothing
  ui_dump | tr '>' '\n' | awk -v want="text=\"$1\"" -v id="id/$2\"" '
    /id\/card_name"/ { hit = index($0, want) > 0 }
    index($0, id) && hit { print; exit }'
}

# The same button on the list, pressed without opening the proxy first.
card_toggle() { # card_toggle NAME
  local x y
  x=""
  y=""
  read -r x y <<EOF
$(card_line "$1" card_toggle |
  sed -n 's/.*bounds="\[\([0-9]*\),\([0-9]*\)\]\[\([0-9]*\),\([0-9]*\)\]".*/\1 \2 \3 \4/p' |
  awk '{ if (NF == 4) print int(($1 + $3) / 2), int(($2 + $4) / 2) }')
EOF
  [ -n "$x" ] || return 1
  tap "$x" "$y"
  settle
  dismiss_battery
}

# Is the app on the Doze allowlist a boot restart needs?
battery_exempt() { shell cmd deviceidle whitelist | grep -q 'org.phonelink.proxy'; }

# Whether the list says that proxy is the one running: the card's state word
# and the word on its button are the two halves of the same answer.
card_state() { # card_state NAME -> Running|Stopped|(nothing)
  card_line "$1" card_state | sed -n 's/.*text="\([^"]*\)".*/\1/p'
}

card_button_text() { # card_button_text NAME -> Start|Stop|(nothing)
  card_line "$1" card_toggle | sed -n 's/.*text="\([^"]*\)".*/\1/p'
}

# The list is the way in and Back is the way out, so every step that wants a
# particular proxy starts by making sure the list is showing.
panel_home() {
  local attempt xml
  for attempt in 1 2 3; do
    xml=$(ui_dump) || xml=""
    # The list shows either the button that makes a new proxy or the list's
    # own scroll area; a dump holds only what is visible, so either one being
    # there is what "the list is showing" means.
    if printf '%s' "$xml" | grep -q 'id/new_profile"\|id/home_scroll"'; then
      return 0
    fi
    if printf '%s' "$xml" | grep -q "id/header_title"; then
      # The panel is up, on a proxy's page: Back is the way out to the list.
      back >/dev/null 2>&1
    else
      # The panel is not up at all — pressing Back here would land on the
      # launcher, so bring the panel up instead.
      shell am start -W -n "$PKG/.MainActivity" >/dev/null 2>&1
    fi
    settle
  done
  return 1
}

panel_open() { # panel_open NAME -> taps that proxy's card
  panel_home || return 1
  local x y
  # A card below the fold is not in a dump, and a long list can put any card
  # there, so the list is scrolled down until the name shows up.
  for _ in 1 2 3 4 5 6 7 8; do
    x=""
    y=""
    read -r x y <<EOF
$(ui_dump | tr '>' '\n' | grep "id/card_name\"" | grep "text=\"$1\"" | head -1 |
  sed -n 's/.*bounds="\[\([0-9]*\),\([0-9]*\)\]\[\([0-9]*\),\([0-9]*\)\]".*/\1 \2 \3 \4/p' |
  awk '{ if (NF == 4) print int(($1 + $3) / 2), int(($2 + $4) / 2) }')
EOF
    if [ -n "$x" ]; then
      tap "$x" "$y"
      settle
      ui_dump | grep -q "id/back\""
      return $?
    fi
    swipe 1300 2200 1300 1200 200
    settle
  done
  return 1
}

ui_tap_id() { # ui_tap_id ID -> taps that node where it is, without scrolling
  # A node that a tap has just caused to appear — a dialog's button, say — is
  # not in the capture taken a moment later, and a capture is cheap enough to
  # keep asking for a few seconds.
  local x y attempt
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    x=""
    y=""
    read -r x y <<EOF
$(ui_bounds "$1")
EOF
    if [ -n "$x" ]; then
      tap "$x" "$y"
      settle
      return 0
    fi
    wait_change 500
  done
  return 1
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
    swipe 1300 2200 1300 1200 200
    settle
  done
  return 1
}

panel_tap() { # panel_tap ID, scrolling down until the control is on screen
  local id=$1 x y
  panel_top
  # The Log page is the tall one: its Clear button sits under a long log.
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
    x=""
    y=""
    read -r x y <<EOF
$(ui_bounds "$id")
EOF
    if [ -n "$x" ]; then
      tap "$x" "$y"
      settle
      return 0
    fi
    swipe 1300 2200 1300 1200 200
    settle
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

# The panel has a password field, and the phone's autofill service answers it
# with a "save this password?" sheet that takes the focus and would swallow the
# taps of the next step. It is off for the run and put back afterwards.
autofill_service=""
quiet_autofill() {
  autofill_service=$(shell settings get secure autofill_service 2>/dev/null |
    tr -d '\r')
  shell settings put secure autofill_service null >/dev/null 2>&1
}

restore_autofill() {
  case $autofill_service in
    '' | null | *://*) return 0 ;;
  esac
  shell settings put secure autofill_service "$autofill_service" >/dev/null 2>&1
}

# Play Protect offers to send an app it does not know for a security check on
# install, and `adb install` waits for that answer — a run then hangs in its
# install step behind a dialog nobody can see. It is off for the run and put
# back afterwards.
verifier_setting=""
quiet_play_protect() {
  verifier_setting=$(shell settings get global verifier_verify_adb_installs |
    tr -d '\r')
  shell settings put global verifier_verify_adb_installs 0 >/dev/null 2>&1
}

restore_play_protect() {
  case $verifier_setting in
    '' | null) return 0 ;;
  esac
  shell settings put global verifier_verify_adb_installs "$verifier_setting" \
    >/dev/null 2>&1
}

unlock_phone() {
  # A waiting step can outlive a short screen timeout, and then every dump is
  # taken from a sleeping phone. Ten minutes is longer than this run.
  if [ -z "$screen_timeout" ]; then
    screen_timeout=$(shell settings get system screen_off_timeout 2>/dev/null |
      tr -d '\r')
    case $screen_timeout in "" | null | *[!0-9]*) screen_timeout=60000 ;; esac
    shell settings put system screen_off_timeout 600000 >/dev/null 2>&1
  fi
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
# screenrecord needs an unlocked screen, and the snapshots are only useful
# once the app is on it.
quiet_autofill
quiet_play_protect
# The fast path for every dump in the run, when the capture app is there. It is
# installed and its service enabled here, so even the first step uses it, and
# it does not depend on PHONE_LIVE_CAPTURE: that switch is about the artifacts,
# this is about how the steps read the screen.
if capture_start; then
  ok 'the capture service answers a request'
else
  printf 'SKIP the capture service (%s); dumps stay on uiautomator, which is\n' \
    "$CAPTURE_APK"
  printf '     about 2.5 s each instead of about 0.3 s.\n'
fi
start_capture

step 'install'
if phone install -r -g "$APK" >/dev/null 2>&1; then
  ok 'installs'
else
  bad 'installs'
  printf '\n%d passed, %d failed\n' "$pass" "$fail"
  exit 1
fi
# A run that was killed leaves its own harness-* profiles behind, and a pile of
# them pushes the next run's cards off the screen. They belong to this harness,
# so they go before anything looks at the list.
leftovers=$(shell dumpsys activity service "$SERVICE" 2>/dev/null |
  grep -o '"harness-[0-9a-z-]*"' | tr -d '"' | sort -u)
if [ -n "$leftovers" ]; then
  printf '  clearing profiles left by an earlier run: %s\n' "$(echo $leftovers)"
  for name in $leftovers; do
    shell am start-foreground-service -n "$SERVICE" \
      -a org.phonelink.proxy.action.DELETE_PROFILE --es profile "$name" \
      >/dev/null 2>&1
    sleep 1
  done
fi


step 'panel'
# Only a crash from this run should fail the step, and the buffer can still
# hold one from before.
phone logcat -b crash -c >/dev/null 2>&1
if panel_opens; then ok 'the panel opens'; else bad 'the panel opens'; fi
if panel_home; then
  ok 'the panel opens on the list of proxies'
else
  bad 'the panel opens on the list of proxies'
  panel_where
fi
if ui_dump | grep -q 'id/new_profile"'; then
  ok 'the list offers a new proxy'
else
  bad 'the list offers a new proxy'
fi

step 'auto start'
start_app --es ssid "$SSID" --ez any_network false --ez auto_start true
if wait_foreground; then
  ok 'auto_start starts the service'
else
  bad 'auto_start starts the service'
  shell dumpsys activity services "$PKG" | head -3
  phone logcat -d -s phone-link-proxy | tail -5
fi
save_profile harness-panel
open_panel
if panel_open harness-panel; then
  ok 'a card opens that proxy'
else
  bad 'a card opens that proxy'
  panel_where
fi
if panel_auto_start_checked; then
  ok 'the open proxy shows auto_start on'
else
  bad 'the open proxy shows auto_start on'
fi

step 'header warning'
# The mark in the header is the battery warning, so take the exemption away and
# put it back exactly as it was found.
exempt=no
if battery_exempt; then exempt=yes; fi
shell cmd deviceidle whitelist -"$PKG" >/dev/null 2>&1
# renderBattery() runs on resume, so leave the panel and come back.
home >/dev/null 2>&1
open_panel
if ui_dump | grep -q 'id/warning"'; then
  ok 'the header warns while a reboot restart cannot work'
else
  bad 'the header warns while a reboot restart cannot work'
fi
panel_tap warning
if wait_for 'Let the proxy restart by itself' 2000; then
  ok 'the mark opens the battery request'
else
  bad 'the mark opens the battery request'
fi
back >/dev/null 2>&1
settle
if [ "$exempt" = yes ]; then
  shell cmd deviceidle whitelist +"$PKG" >/dev/null 2>&1
  home >/dev/null 2>&1
  settle
  open_panel
  if ui_dump | grep -q 'id/warning"'; then
    bad 'the mark goes away with the exemption'
  else
    ok 'the mark goes away with the exemption'
  fi
else
  printf 'SKIP the mark going away: the phone was not exempt before this run\n'
fi

step 'panel state'
open_panel
panel_open harness-panel
panel_tab service
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
# The open proxy is the one that starts: Start stores the form first, so the
# anonymous box is applied to that saved configuration and not just to a form.
# The one button is Start only while nothing runs, so stop first.
shell am start-foreground-service -n "$SERVICE" -a "$STOP" >/dev/null 2>&1
sleep 2
open_panel
if panel_open harness-panel && panel_tab listener && panel_tap anonymous &&
  panel_toggle; then
  if wait_anonymous yes; then
    ok 'the anonymous checkbox is applied by Start'
  else
    bad 'the anonymous checkbox is applied by Start'
  fi
  # Put authentication back through the same controls: the running proxy is
  # stopped, the box is ticked again and it is started, so the tunnel works
  # with credentials again and nobody without them does.
  panel_toggle
  panel_tab listener
  panel_tap anonymous
  panel_toggle
  if wait_anonymous no; then
    ok 'unticking it asks for a password again'
  else
    bad 'unticking it asks for a password again'
  fi
  if through_proxy; then
    ok 'and the credentials still work'
  else
    bad 'and the credentials still work'
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

step 'profiles over adb'
start_app --es ssid "$SSID" --ez any_network false --ei port "$PORT"
sleep 2
if save_profile harness-one; then
  if phone logcat -d -s phone-link-proxy | grep -q 'saved configuration "harness-one"'; then
    ok 'SAVE_PROFILE keeps the running configuration'
  else
    bad 'SAVE_PROFILE keeps the running configuration'
  fi
  if shell dumpsys activity service "$SERVICE" | grep -q '"harness-one" — port'; then
    ok 'dumpsys lists what is saved'
  else
    bad 'dumpsys lists what is saved'
  fi
  open_panel
  if panel_home &&
    ui_dump | tr '>' '\n' | grep 'id/card_name"' | grep -q 'text="harness-one"'; then
    ok 'the panel lists a configuration saved over adb'
  else
    bad 'the panel lists a configuration saved over adb'
    panel_where
  fi
  # Move the running configuration somewhere else, then start the saved one by
  # name: it has to come back exactly as it was saved.
  start_app --es ssid "$SSID" --ez any_network false --ei port 19999
  sleep 2
  shell am start-foreground-service -n "$SERVICE" \
    -a org.phonelink.proxy.action.START --es profile harness-one >/dev/null 2>&1
  sleep 3
  if through_proxy; then
    ok 'START --es profile brings a saved configuration back'
  else
    bad 'START --es profile brings a saved configuration back'
  fi
  # A configuration is the whole panel, so the two service switches come back
  # with it: turn them off, start the saved one by name, and read the store's
  # answer out of dumpsys.
  start_app --es ssid "$SSID" --ez any_network false --ez auto_start false \
    --ez adb_wifi false
  sleep 2
  shell am start-foreground-service -n "$SERVICE" \
    -a org.phonelink.proxy.action.START --es profile harness-one >/dev/null 2>&1
  sleep 3
  now=$(shell dumpsys activity service "$SERVICE")
  if printf '%s\n' "$now" | grep -q 'auto-start  true'; then
    ok 'the saved auto-start comes back with the configuration'
  else
    bad 'the saved auto-start comes back with the configuration'
  fi
  if printf '%s\n' "$now" | grep -q 'adb_wifi    true'; then
    ok 'the saved wireless-debugging switch comes back with it'
  else
    bad 'the saved wireless-debugging switch comes back with it'
  fi
  shell am start-foreground-service -n "$SERVICE" -a "$STOP" >/dev/null 2>&1
  sleep 2
  shell am start-foreground-service -n "$SERVICE" \
    -a org.phonelink.proxy.action.START --es profile harness-absent >/dev/null 2>&1
  sleep 2
  if port_closed; then
    ok 'an unknown profile name starts nothing'
  else
    bad 'an unknown profile name starts nothing'
  fi
  if phone logcat -d -s phone-link-proxy |
    grep -q 'no saved configuration called "harness-absent"'; then
    ok 'and says why'
  else
    bad 'and says why'
  fi
  # Leave the harness on the configuration the remaining steps expect.
  start_app --es ssid "$SSID" --ez any_network false --ei port "$PORT"
  sleep 2
  shell am start-foreground-service -n "$SERVICE" \
    -a org.phonelink.proxy.action.DELETE_PROFILE --es profile harness-one \
    >/dev/null 2>&1
  sleep 2
  # Only the saved lines: the dump also names the proxy that is in use.
  if shell dumpsys activity service "$SERVICE" | grep 'saved' |
    grep -q '"harness-one"'; then
    bad 'DELETE_PROFILE removes a saved configuration'
  else
    ok 'DELETE_PROFILE removes a saved configuration'
  fi
fi

step 'plain Save'
# Save on the open proxy writes the whole form back to it — listener and the
# service switches — without going through Save as….
start_app --es ssid "$SSID" --ez any_network false --ei port "$PORT"
sleep 2
save_profile harness-save
open_panel
if panel_open harness-save; then
  ok 'the card opens the proxy to save'
else
  bad 'the card opens the proxy to save'
  panel_where
fi
panel_tab listener
panel_tap port
# Typing here replaces the field in place rather than clearing it with a dozen
# Backspaces and an `input text` of its own: the field already has the focus,
# and a sequence takes it from there. Tapping the field raised the keyboard,
# which covers the Save row, so the phone puts it away before anything looks
# for that button — and only if one is really up.
if ! sequence 'text 18099; wait-quiet 250; keyboard-off; wait-quiet 300'; then
  bad 'the port field takes a number'
  panel_where
fi
panel_tap save
settle
if shell dumpsys activity service "$SERVICE" | grep -q 'harness-save.*port 18099'; then
  ok 'Save writes the form to the open proxy'
else
  bad 'Save writes the form to the open proxy'
fi
panel_tab service
panel_tap auto_start
want=off
if [ "$(panel_checked auto_start)" = yes ]; then want=on; fi
panel_tap save_service
settle
if shell dumpsys activity service "$SERVICE" |
  grep -q "harness-save.*auto-start $want"; then
  ok 'Save writes the switches too'
else
  bad "Save writes the switches too (wanted $want)"
  panel_where
fi
delete_profile_by_adb harness-save

step 'card toggle'
# The list starts and stops a proxy by itself now: the button on the card has
# to follow what the service reports, and so does the word next to the dot.
start_app --es ssid "$SSID" --ez any_network false --ei port "$PORT"
sleep 2
save_profile harness-card
shell am start-foreground-service -n "$SERVICE" -a "$STOP" >/dev/null 2>&1
sleep 2
open_panel
if panel_home; then
  state=$(card_state harness-card)
  if [ "$state" = Stopped ]; then
    ok 'a stopped proxy says so on its card'
  else
    bad "a stopped proxy says so on its card (\"$state\")"
    panel_where
  fi
  if [ "$(card_button_text harness-card)" = Start ]; then
    ok 'and its card offers Start'
  else
    bad 'and its card offers Start'
  fi
  if card_toggle harness-card; then
    sleep 2
    if foreground; then ok 'the card starts that proxy'; else
      bad 'the card starts that proxy'
    fi
    if through_proxy; then ok 'and requests go through it'; else
      bad 'and requests go through it'
    fi
    state=$(card_state harness-card)
    if [ "$state" = Running ]; then
      ok 'the card follows the state it created'
    else
      bad "the card follows the state it created (\"$state\")"
    fi
    if [ "$(card_button_text harness-card)" = Stop ]; then
      ok 'and offers Stop while it runs'
    else
      bad 'and offers Stop while it runs'
    fi
    if card_toggle harness-card; then
      sleep 2
      if foreground; then bad 'a second press stops it'; else
        ok 'a second press stops it'
      fi
      if [ "$(card_state harness-card)" = Stopped ]; then
        ok 'and the card goes back to Stopped'
      else
        bad 'and the card goes back to Stopped'
      fi
    else
      bad 'the card button can be pressed again'
    fi
  else
    bad 'the card button can be pressed'
    panel_where
  fi
else
  bad 'the list is reachable'
fi
delete_profile_by_adb harness-card

step 'rename'
# A name is a label on the settings, so renaming moves the settings, the
# service switches and the mark of which proxy is in use under the new name.
start_app --es ssid "$SSID" --ez any_network false --ei port "$PORT"
sleep 2
save_profile harness-old
# Start it by name, so that proxy is the one the service reports as in use.
shell am start-foreground-service -n "$SERVICE" \
  -a "$START" --es profile harness-old >/dev/null 2>&1
sleep 3
open_panel
if panel_open harness-old; then
  ok 'the proxy to rename opens'
else
  bad 'the proxy to rename opens'
  panel_where
fi
if menu_pick Rename; then
  # The dialog opens on its name field, so the new name goes straight into the
  # focused field and the button follows it — one straight line, one message.
  # The dialog's buttons leaving the screen is what says it closed: the page
  # behind has edit fields of its own and would answer any question about
  # "no EditText on screen" wrongly.
  if sequence 'wait class=android.widget.EditText 2000; text harness-renamed; tap-id button1 3000; wait-gone id=button1 3000'; then
    if shell dumpsys activity service "$SERVICE" | grep 'saved' |
      grep -q '"harness-renamed"'; then
      ok 'the menu renames a proxy'
    else
      bad 'the menu renames a proxy'
      panel_where
    fi
    if shell dumpsys activity service "$SERVICE" | grep 'saved' |
      grep -q '"harness-old"'; then
      bad 'and the old name is gone'
    else
      ok 'and the old name is gone'
    fi
    if [ "$(ui_text header_title)" = harness-renamed ]; then
      ok 'the page follows the new name'
    else
      bad "the page follows the new name ($(ui_text header_title))"
    fi
  else
    bad 'the rename dialog can be answered'
    panel_where
  fi
else
  bad "the menu offers Rename"
fi
# The service does the same from adb, for an agent with no screen.
shell am start-foreground-service -n "$SERVICE" \
  -a org.phonelink.proxy.action.RENAME_PROFILE --es profile harness-renamed \
  --es to harness-adb >/dev/null 2>&1
sleep 2
if shell dumpsys activity service "$SERVICE" | grep 'saved' |
  grep -q '"harness-adb"'; then
  ok 'RENAME_PROFILE renames from adb'
else
  bad 'RENAME_PROFILE renames from adb'
fi
if shell dumpsys activity service "$SERVICE" | grep -q 'profile *"harness-adb"'; then
  ok 'and the proxy in use keeps its place'
else
  bad 'and the proxy in use keeps its place'
fi
delete_profile_by_adb harness-adb

step 'info marks'
# Every control carries its own i, and the app's own Info is behind the burger.
start_app --es ssid "$SSID" --ez any_network false --ei port "$PORT"
sleep 2
save_profile harness-info
open_panel
if panel_open harness-info; then
  ok 'a proxy opens for its info marks'
else
  bad 'a proxy opens for its info marks'
  panel_where
fi
if panel_tab listener && sequence 'tap-id info_port 5000; wait id=alertTitle 2000'; then
  if ui_text alertTitle | grep -q 'Port'; then
    ok 'the i next to a field explains that field'
  else
    bad 'the i next to a field explains that field'
    panel_where
  fi
  back >/dev/null 2>&1
  settle
else
  bad 'the field carries an i'
fi
if panel_tab log && sequence 'tap-id info_log 5000; wait id=alertTitle 2000'; then
  if ui_dump | grep -q 'id/alertTitle"'; then
    ok 'the log page carries one too'
  else
    bad 'the log page carries one too'
  fi
  back >/dev/null 2>&1
  settle
else
  bad 'the log page carries an i'
fi
if menu_pick 'About this app' && wait_for 'RENAME_PROFILE' 2000; then
  if ui_dump | grep -q 'RENAME_PROFILE'; then
    ok 'About this app is in the menu and shows the contract'
  else
    bad 'About this app is in the menu and shows the contract'
  fi
  back >/dev/null 2>&1
  settle
else
  bad 'the menu has About this app'
fi
delete_profile_by_adb harness-info

step 'new proxy'
# The list's way in: name it, and the proxy that was created opens itself.
panel_home
if panel_tap new_profile &&
  sequence 'wait class=android.widget.EditText 2000; text harness-new; tap-id button1 3000; wait id=back 3000; wait-quiet 250'; then
  if shell dumpsys activity service "$SERVICE" | grep 'saved' |
    grep -q '"harness-new"'; then
    ok 'New proxy is saved under its name'
  else
    bad 'New proxy is saved under its name'
    panel_where
  fi
  if ui_dump | grep -q 'id/back"'; then
    ok 'and it opens for its settings'
  else
    bad 'and it opens for its settings'
  fi
else
  bad 'the list has a New proxy button'
  panel_where
fi
delete_profile_by_adb harness-new

step 'ten proxies'
# Ten saved proxies push the list past one screen. `New proxy` sits under it,
# so it has to stay reachable by scrolling and still save an eleventh.
for i in 1 2 3 4 5 6 7 8 9 10; do
  shell am start-foreground-service -n "$SERVICE" \
    -a org.phonelink.proxy.action.SAVE_PROFILE --es profile "harness-$i" >/dev/null 2>&1
  sleep 1
done
open_panel
if panel_home; then
  ok 'the list is showing'
else
  bad 'the list is showing'
  panel_where
fi
total=$(shell dumpsys activity service "$SERVICE" 2>/dev/null |
  grep -o '"harness-[0-9]*"' | wc -l)
if [ "$total" -ge 10 ]; then
  ok 'ten proxies are saved'
else
  bad "ten proxies are saved ($total in the dump)"
fi
# A dump holds only what is on screen, so the button is reached the way a hand
# would reach it: by scrolling the list to its end.
scrolled=no
for _ in 1 2 3 4 5 6 7 8; do
  if ui_dump | grep -q 'id/new_profile"'; then
    scrolled=yes
    break
  fi
  swipe 1300 2200 1300 1200 200
  settle
done
if [ "$scrolled" = yes ]; then
  ok 'New proxy is still reachable under ten cards'
  if ui_tap_id new_profile &&
    sequence 'wait class=android.widget.EditText 2000; text harness-eleven; tap-id button1 3000; wait id=back 3000; wait-quiet 250'; then
    if shell dumpsys activity service "$SERVICE" | sed -n '/  saved/,$p' |
      grep -q '"harness-eleven"'; then
      ok 'and it saves an eleventh proxy'
    else
      bad 'and it saves an eleventh proxy'
      panel_where
    fi
  else
    bad 'New proxy can be tapped'
    panel_where
  fi
else
  bad 'New proxy is still reachable under ten cards'
  panel_where
fi
# Leave the list as short as the next steps expect: the panel reads the store
# on resume, so it is left and re-opened after the ten are gone.
for i in 1 2 3 4 5 6 7 8 9 10 eleven; do
  shell am start-foreground-service -n "$SERVICE" \
    -a org.phonelink.proxy.action.DELETE_PROFILE --es profile "harness-$i" \
    >/dev/null 2>&1
  sleep 1
done
home >/dev/null 2>&1
open_panel
report=$(shell dumpsys activity service "$SERVICE" 2>/dev/null |
  sed -n '/  saved/,$p' | grep -o '"harness-[0-9]*"' | wc -l)
if [ "${report:-1}" -eq 0 ]; then
  ok 'the ten are gone again'
else
  bad "the ten are gone again ($report left)"
fi

step 'proxy log'
# Start the saved proxy by name so its events carry its name, and move some
# bytes through it: the page shows this run's counters and this proxy's log.
start_app --es ssid "$SSID" --ez any_network false --ei port "$PORT"
sleep 2
save_profile harness-panel
shell am start-foreground-service -n "$SERVICE" \
  -a "$START" --es profile harness-panel >/dev/null 2>&1
sleep 3
if through_proxy; then ok 'the listener still serves'; else bad 'the listener still serves'; fi
open_panel
if panel_open harness-panel; then
  ok 'the proxy with its log is reachable'
else
  bad 'the proxy with its log is reachable'
  panel_where
fi
# The counters and the log share the Log segment now, so nothing has to be
# scrolled: a node below the fold would not be in a dump at all.
panel_tab log
wait_for 'id/traffic"' 3000 || true
traffic=$(ui_dump)
if printf '%s' "$traffic" | grep -q 'id/traffic"'; then
  ok 'the proxy page shows the traffic line'
  if printf '%s' "$traffic" | grep -q 'No traffic in this run yet'; then
    bad 'the counters moved bytes'
    printf '  counters with the page open: %s\n' \
      "$(shell dumpsys activity service "$SERVICE" | grep 'traffic ')"
  else
    ok 'the counters moved bytes'
  fi
else
  bad 'the proxy page shows the traffic line'
  bad 'the counters moved bytes'
  panel_where
fi
if printf '%s' "$traffic" | grep -q 'saved configuration'; then
  ok 'the page shows what happened to this proxy'
else
  bad 'the page shows what happened to this proxy'
fi
if printf '%s' "$traffic" | grep -q "listening on 0.0.0.0:$PORT"; then
  ok 'and the state changes with their port'
else
  bad 'and the state changes with their port'
fi
panel_tap log_clear
# Clearing is a redraw like any other: the screen is watched until it stops
# saying what it said, rather than asked again and again.
if wait_gone 'saved configuration' 3000; then
  ok 'Clear empties the log'
else
  bad 'Clear empties the log'
fi
delete_profile_by_adb harness-panel

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
