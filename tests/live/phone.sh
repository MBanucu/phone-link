#!/usr/bin/env bash
# The phone-facing half of the live harness: how to look at and drive the phone,
# and nothing about what a step claims. Sourced by proxy-app.sh, which owns the
# verdicts (ok, bad, step), the run's evidence and the steps themselves — so a
# helper added for one step is added where it belongs, and a step reads as
# claims rather than as adb.
#
# Needs the caller's variables: ROOT, serial, ARTIFACTS, PORT, PKG, RES, SERVICE,
# ACTIVITY,
# SSID, USER_NAME, PASSWORD, CAPTURE_PKG, CAPTURE_DIR, DEVICETEST_PKG and the
# capture/devicetest APK paths.
set -u

# What this layer remembers between calls.
capture_dumps=0
capture_old_services=""
capture_old_enabled=""
# Which instruction of the last sequence stopped it, for a step that failed.
sequence_stopped=""

phone() { adb -s "$serial" "$@"; }

shell() { phone shell "$@"; }

# The phone's monotonic clock in nanoseconds, the one actions.csv, input.csv and
# the capture index are stamped with. Read when a step starts and when one
# fails, so a failure can later be shown from the recording it happened in.
device_ns() {
  local seconds
  seconds=$(shell cut -d' ' -f1 /proc/uptime 2>/dev/null | tr -d '\r')
  case $seconds in
    '' | *[!0-9.]*) return 1 ;;
  esac
  awk -v t="$seconds" 'BEGIN { printf "%.0f", t * 1e9 }'
}

# uiautomator serves one dump at a time; a dump that arrives while another is
# running can fail outright rather than queue, and a failed one costs a step a
# retry, so the snapshots and the steps share this lock. A lock that outlives
# a dozen seconds is treated as left behind by something that died holding it,
# so a run cannot wedge.
# --- the capture service, and the record it keeps ------------------------
# The screen is read by an accessibility service that is installed for the run:
# a capture is a tenth of a second where `uiautomator dump` is two and a half,
# and the gesture that changed the screen is dispatched by the same service, so
# the action and the frame it caused share the phone's clock.

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
  # Only believe it when a capture comes back: a service that could not bind
  # looks exactly like one that was never enabled. This phone's own startup
  # policy can hold a freshly installed app's service for a while, so the answer
  # is waited for — thirty seconds, then the run goes on without captures.
  local attempt
  for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    sleep 2
    if capture_dump | grep -q '<hierarchy'; then
      capture_dumps=1
      return 0
    fi
  done
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

# One argument for the phone's shell: a needle is XML, and XML is full of the
# punctuation a shell would eat.
# --- waiting on the phone instead of on the clock -------------------------
# A step used to tap and then sleep: too long when the phone is quick, too short
# when it is busy. The service holds a broadcast until the screen it already
# watches says what the step is waiting for, so the step continues on the event
# it caused — and, because it is the same service, the instant it continued is
# in the run's record too.

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

# The service's own words, watched rather than asked once: an action sent over
# adb is applied as the intent arrives, and the panel may be writing its view of
# the store at the same moment — a fixed sleep is a guess at whose write lands
# second, and a check that guesses fails when it guessed right and lost.
watch_dump() { # watch_dump PATTERN [MS] -> the dump holds it
  local pattern=$1 waited=0 limit=${2:-5000}
  while :; do
    if shell dumpsys activity service "$SERVICE" 2>/dev/null | grep -q "$pattern"; then
      return 0
    fi
    [ "$waited" -ge "$limit" ] && return 1
    sleep 0.2
    waited=$((waited + 200))
  done
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
sequence() { # sequence 'SCRIPT' -> 0 when every instruction ran
  [ "$capture_dumps" = 1 ] || return 1
  local out
  sequence_value=""
  sequence_stopped=""
  out=$(shell am broadcast -a "$CAPTURE_PKG.SEQUENCE" --es script "$(phone_arg "$1")" \
    -n "$CAPTURE_PKG/.DumpReceiver" 2>/dev/null)
  case $out in
    *'result=0'*)
      # A script that read a field answers with what it found.
      sequence_value=$(printf '%s' "$out" | sed -n 's/.*data="\([^"]*\)".*/\1/p')
      return 0 ;;
  esac
  # The instruction that stopped it, for the step's own diagnostics: the
  # record in actions.csv has the same line with its instant.
  sequence_stopped=$(printf '%s' "$out" |
    sed -n 's/.*data="\([^"]*\)".*/\1/p')
  return 1
}

# The panel, up and still, whatever it was showing before.
open_panel() {
  shell am start -W -n "$ACTIVITY" >/dev/null 2>&1
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
    # screenrecord puts the index at the end; the pixels are already H.264, so
    # a copy pass moves it to the front and the file plays while it sits in the
    # run's folder. A host without ffmpeg keeps the recording as it came, and
    # a failed pass is a failed check, not a lost file.
    if [ "${PHONE_LIVE_REMUX:-1}" != 0 ] && [ -f "$ARTIFACTS/screen.mp4" ]; then
      if bash "$REMUX" "$ARTIFACTS/screen.mp4" >"$ARTIFACTS/remux.txt" 2>&1; then
        remuxed=1
      else
        remux_failed=1
      fi
    fi
  fi
  calibrate_clock
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
      { printf '%s' "$xml" | grep -q "$RES:id/header_title" ||
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
          shell am start -W -n "$ACTIVITY" >/dev/null 2>&1
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
  # The page area is the phone's business: it knows how tall the screen is and
  # where the page's own scroller begins.
  sequence 'scroll-top'
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
    grep -c "$ACTIVITY")"
  printf '  app nodes: %s\n' "$(ui_dump | grep -o "$RES:id/[a-z_]*" | wc -l)"
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
      shell am start -W -n "$ACTIVITY" >/dev/null 2>&1
    fi
    settle
  done
  return 1
}

panel_open() { # panel_open NAME -> taps that proxy's card
  panel_home || return 1
  # A card below the fold is not in a dump, and a long list can put any card
  # there: the phone scrolls the list down to that name, taps that card and
  # waits for the page to come up, all in one go. The selector names the card's
  # own name node, so it cannot be another card's.
  sequence "tap-scroll \"id=card_name text=$1\" 12000; wait id=back 4000"
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
  local id=$1
  sequence "scroll-to id=$id 8000; read id=$id 2000" || return 1
  [ -n "$sequence_value" ] || return 1
  printf '%s\n' "$sequence_value"
}

panel_tap() { # panel_tap ID, scrolling down until the control is on screen
  # The Log page is the tall one: its Clear button sits under a long log, and
  # the phone scrolls after it for as long as that takes.
  sequence "tap-scroll id=$1 12000; wait-quiet 250" && return 0
  # A scroll can come back without the control when it ran while the page was
  # still redrawing; one more try costs a second, a lost step a minute.
  settle
  sequence "scroll-top; tap-scroll id=$1 12000; wait-quiet 250"
}

# Tile clicks are ignored while the keyguard is up, and uiautomator cannot
# dump a sleeping panel, so unlock through the project's own command. It reads
# the root-only secrets, so a run without sudo leaves the phone locked and the
# steps that need it say so instead of failing.
keyguard_showing() {
  shell dumpsys window policy | grep -q 'showing=true'
}

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
