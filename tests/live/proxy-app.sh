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
#  10e. delete a running proxy over adb and from the menu, and require the
#      port to close both ways with the other proxy still serving,
#  10d. the page's own checks, run by an instrumentation inside the proxy's
#      process (tests/live/../android/devicetest): two saved proxies, one
#      started from its card, the other's page saying Start adds it beside,
#      that page starting and stopping it, and the marks on both cards,
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
# Two files: this one holds the run — its configuration, the verdicts, the
# evidence and the steps with the claims they make — and `phone.sh` beside it
# holds how to look at and drive the phone (captures, gestures, sequences, the
# panel's navigation, the unlock and the settings). A step reads as a claim;
# when it needs a new way to touch the phone, that goes in `phone.sh`.
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
#
# A tunnel check that fails asks the phone whose fault it was: the route the
# tunnel really takes (the cellular interface the app reports it is bound to,
# then a ping through it), the phone's own default route, the app's last word
# and byte counters for that port — printed under the FAIL and written to
# uplink.csv. A flaky uplink then reads as a flaky uplink instead of a proxy
# bug, which is a rerun not spent. PHONE_LIVE_TUNNEL_URL (default
# https://example.com) is the name those checks ask for.
#
# PHONE_LIVE_ONLY="card toggle,rename" runs just the steps it names, by the
# name the log prints, instead of all twenty-three. The steps are not
# independent — most assume the phone is awake, the app is installed and a
# proxy is saved under the name their page opens by — so a filtered run always
# does that preamble (the `unlock` and `install` steps, then one proxy on the
# test port), and says in the log and in timings.csv that it was partial: it
# writes a PARTIAL row where a full run writes TOTAL, so the
# history can never mistake it for a run that was green all the way through.
#
# While it runs it says how much is left, from that same history: the plan line
# prices every step at the median of its last few runs, and a line every fifteen
# seconds names the step it is in, how long that step has been running, what it
# usually takes and what the run has left. A step that outlives its estimate
# makes the whole run look slower instead of leaving a number that stopped
# moving, and a step that runs away — twice its usual time and half a minute
# over it — says so in a line of its own, once, so a hang is not just a number
# that keeps growing. The last line says what the run really took, which is what
# the next plan is judged against. PHONE_LIVE_ETA=0 turns it off;
# PHONE_LIVE_ETA_EVERY (seconds) and PHONE_LIVE_ETA_RUNS (how many runs a median
# is taken over) are the knobs.
set -u

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
# The build under test, and the package it is installed as: the test build, so a
# run never replaces the proxy the phone lives on (build.sh builds both from the
# same sources). The classes keep their package under the other id, which is why
# a component is `$PKG/$CLASS.Service` — see android/AndroidManifest.xml.
APK=${PROXY_APP_APK:-$ROOT/android/build/phone-link-proxy-test.apk}
PORT=${PROXY_APP_PORT:-18080}
PKG=${PHONE_PROXY_PKG:-org.phonelink.proxy.test}
CLASS=org.phonelink.proxy
# The package the resource table is packaged under. build.sh relinks the
# manifest under the test id but not the resources, so a node in a screen dump
# carries the installed id in `package` and this one in `resource-id`.
RES=$CLASS
SERVICE=$PKG/$CLASS.ProxyService
ACTIVITY=$PKG/$CLASS.MainActivity
# The other instance, if the phone has one: this run must leave it alone, and
# saying so is a check rather than a promise.
STABLE=${PHONE_STABLE_PKG:-org.phonelink.proxy}
START=org.phonelink.proxy.action.START
STOP=org.phonelink.proxy.action.STOP
USER_NAME=phonelink-test
# The name a tunnel check asks for. Overridable so a run can point at a server
# of its own, and so the failure path can be exercised on purpose.
TUNNEL_URL=${PHONE_LIVE_TUNNEL_URL:-https://example.com}
PASSWORD=phonelink-test-password
# The capture app: a test-only accessibility service that writes the screen as
# XML in about a tenth of a second, where `adb shell uiautomator dump` costs
# seconds. It is installed for the run and removed afterwards;
# PHONE_LIVE_DUMPS=uiautomator uses the slow path on purpose.
CAPTURE_APK=${PROXY_CAPTURE_APK:-$ROOT/android/build/capture.apk}
CAPTURE_PKG=${PROXY_CAPTURE_PKG:-org.phonelink.capture}
CAPTURE_DIR=/sdcard/Android/data/$CAPTURE_PKG/files
# The on-device panel checks: an instrumentation that runs inside the proxy's
# process and reads the page's own views (devicetest/ in the app). Same deal —
# installed for the run, removed afterwards.
DEVICETEST_APK=${PROXY_DEVICETEST_APK:-$ROOT/android/build/devicetest.apk}
DEVICETEST_PKG=${PROXY_DEVICETEST_PKG:-org.phonelink.proxytest}
# The flashes that tie the phone's clock to the recording, and the tool that
# fits them: eight edges held 200 ms each, at the start of the run and again
# just before the recorder stops.
FLASH_EDGES=${PHONE_LIVE_FLASH_EDGES:-8}
FLASH_PERIOD=${PHONE_LIVE_FLASH_PERIOD:-200}
CLOCK=${PHONE_LIVE_CLOCK_SH:-$ROOT/tests/live/clock.sh}

pass=0
fail=0
# The step being timed, so the CSV gets one row per step, not just the total.
step_name=""
step_start=0
step_pass=0
step_fail=0

# Every verdict is also a row in checks.csv, so a failed run can be read as a
# list instead of as scrollback: the step, whether it was good, the harness file
# and line that asked, the function it was asked from, when the laptop decided
# it, and the claim itself.
checks_row() { # checks_row VERDICT CLAIM FUNCTION FILE LINE
  local file=${4#"$ROOT"/}
  file=${file#./}
  printf '%s,%s,%s,%s,%s,%s,%s,"%s"\n' \
    "$run_id" "$step_name" "$1" "$file" "$5" "$3" "$(now_ms)" "${2//\"/\"\"}" \
    >>"$CHECKS"
}

# What happened just before a failed check, from the phone's own record: its
# clock, the last actions it took and the last screen it captured. Best effort,
# and only on a failure — a run whose capture service never came up still says
# which check failed and where.
failure_context() {
  [ "$capture_dumps" = 1 ] || return 0
  local clock actions captures
  # One string: adb joins its arguments, and the space would be lost.
  clock=$(shell "cut -d' ' -f1 /proc/uptime" 2>/dev/null)
  actions=$(shell tail -n 3 "$CAPTURE_DIR/actions.csv" 2>/dev/null | tr '\n' '|')
  captures=$(shell tail -n 2 "$CAPTURE_DIR/ui-index.csv" 2>/dev/null | tr '\n' '|')
  if [ -n "${last_check:-}" ]; then
    printf '  previous check: %s\n' "$last_check"
  fi
  if [ -n "$clock" ]; then
    printf '  phone clock: %s s since boot (device_ns ~%s)\n' \
      "$clock" "$(printf '%s' "$clock" | awk '{ printf "%d", $1 * 1000000000 }')"
  fi
  [ -n "$actions" ] && printf '  last actions:  %s\n' "$actions"
  [ -n "$captures" ] && printf '  last captures: %s\n' "$captures"
  return 0
}

ok() {
  pass=$((pass + 1))
  step_pass=$((step_pass + 1))
  printf 'PASS %s\n' "$*"
  checks_row pass "$*" "${FUNCNAME[1]}" "${BASH_SOURCE[1]}" "${BASH_LINENO[0]}"
  last_check="PASS $*"
}
bad() {
  fail=$((fail + 1))
  step_fail=$((step_fail + 1))
  printf 'FAIL %s\n' "$*"
  checks_row fail "$*" "${FUNCNAME[1]}" "${BASH_SOURCE[1]}" "${BASH_LINENO[0]}"
  failure_context
  last_check="FAIL $*"
}

# Milliseconds since the epoch, for the per-step timings.
now_ms() { date +%s%3N; }

# The link itself, before anything is read through it. A phone whose wireless
# debugging has gone away answers nothing, and every read below then comes back
# empty — which reads as "the phone has no Wi-Fi", a different fault with a
# different fix. A port that merely rotated is not a lost phone: adbd advertises
# the new one, and `avahi-browse -rtp` prints it in a second.
adb_link() {
  local state found endpoint
  state=$(phone get-state 2>&1 | head -1)
  [ "$state" = device ] && return 0
  found=$(timeout 20 avahi-browse -rtp _adb-tls-connect._tcp 2>/dev/null || true)
  endpoint=$(printf '%s\n' "$found" | awk -F';' \
    '$1 == "=" && $3 == "IPv4" && $8 != "" && $9 ~ /^[0-9]+$/ {
      print $8 ":" $9
      exit }')
  if [ -n "$endpoint" ] && [ "$endpoint" != "$serial" ]; then
    adb connect "$endpoint" >/dev/null 2>&1 || true
    if [ "$(adb -s "$endpoint" get-state 2>&1 | head -1)" = device ]; then
      printf 'the phone moved to %s, %s no longer answers\n' "$endpoint" "$serial"
      serial=$endpoint
      return 0
    fi
  fi
  printf 'the adb link is gone: "%s" said "%s"\n' "$state" "$serial" >&2
  if [ -n "$endpoint" ]; then
    printf '  it advertises %s, and that does not answer either: wireless\n' "$endpoint" >&2
    printf '  debugging was just switched, or the phone left this network\n' >&2
  elif printf '%s' "$found" | grep -q '^+'; then
    printf '  adbd is advertised with no address in its record, which is wireless\n' >&2
    printf '  debugging switched off on the phone\n' >&2
  else
    printf '  nothing on this network advertises _adb-tls-connect: the phone is\n' >&2
    printf '  off, elsewhere, or its wireless debugging is off\n' >&2
  fi
  printf '  a cable and phone-adb-wifi turn it back on without the screen\n' >&2
  exit 2
}

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
  eta_mark "$1" "$step_start"
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


# Where this run's evidence goes, and the one file that outlives it.
run_id=$(date -u +%Y%m%dT%H%M%SZ)
ARTIFACTS=${PHONE_LIVE_ARTIFACTS:-$ROOT/result-live/$run_id}
TIMINGS=${PHONE_LIVE_TIMINGS:-$ROOT/result-live/timings.csv}
# This run's checks, one row each; beside it timings.csv, which keeps the
# history of every run.
CHECKS=${PHONE_LIVE_CHECKS:-$ARTIFACTS/checks.csv}
mkdir -p "$ARTIFACTS" "$(dirname "$TIMINGS")"
printf 'run,step,verdict,file,line,function,decided_ms,claim\n' >"$CHECKS"
# The actions that had to go through `input`, each with the interval its
# instant is inside; the ones the phone took itself are in the actions.csv the
# capture service writes, which is pulled with the rest of its files.
printf 'start_ns,end_ns,kind,what\n' >"$ARTIFACTS/input.csv"
# What the phone said about its own route when a tunnel check failed; written
# only on failure, so a green run leaves no rows.
UPLINK=${PHONE_LIVE_UPLINK:-$ARTIFACTS/uplink.csv}
printf 'decided_ms,port,ping_ip,ping_host,egress,verdict\n' >"$UPLINK"

# How to look at and drive the phone lives in its own file; this one decides
# what the phone showed means.
. "$ROOT/tests/live/phone.sh"
# How much of the run is left, from the step timings of the runs before it.
. "$ROOT/tests/live/eta.sh"

# Set when this run woke the phone, so it can be put back to sleep.
unlocked=0
# Set when the steps are over, so cleanup knows the exit status is its to set.
finished=0
# Set when PHONE_LIVE_ONLY asked for some of the steps; a partial run is never
# written to timings.csv as a TOTAL row.
partial=0
# Set when this run changed the screen timeout, so the old one can go back.
screen_timeout=""
# The estimate of what is left: the file the ticker reads, the step prices it
# reads them from, and the plan the last line is judged against.
eta_on=${PHONE_LIVE_ETA:-1}
eta_every=${PHONE_LIVE_ETA_EVERY:-15}
eta_pid=""
eta_state=""
eta_planned=""
ETA_STATE=""
ETA_ORDER=()
ETA_PLAN_MS=0

# --- the evidence a failed run leaves behind -----------------------------

capturing=0
screenrecord_pid=""
snapshot_pid=""
run_start=$(now_ms)
# How well the phone's clock and the recording agree, from the flashes.
clock_summary=""
clock_fit=""
clock_failed=""



cleanup() {
  stop_capture
  # The estimate stops before the epilogue: its checks are part of the run's
  # verdict, and a ticker line between them would read as one of them.
  if [ -n "${eta_pid:-}" ]; then
    kill "$eta_pid" 2>/dev/null || true
    eta_pid=""
  fi
  # Which profiles are there has to be read before the service is stopped: the
  # dump is empty afterwards, and a guard that reads nothing deletes nothing.
  # Two spaces after the name: the help text above the facts also has a line
  # starting with "saved,".
  local saved
  saved=$(shell dumpsys activity service "$SERVICE" 2>/dev/null |
    sed -n '/  saved  /,$p')
  # Off the phone again: the settings go back to what they were and the test
  # package is uninstalled, so nothing of this run is left behind.
  capture_stop
  phone uninstall "$CAPTURE_PKG" >/dev/null 2>&1
  phone uninstall "$DEVICETEST_PKG" >/dev/null 2>&1
  restore_autofill
  restore_play_protect
  shell am start-foreground-service -n "$SERVICE" -a "$STOP" >/dev/null 2>&1
  shell cmd statusbar collapse >/dev/null 2>&1
  # Whatever this run saved: a crash halfway through must not leave the phone
  # with test proxies in its list. Only the names that are really there are
  # named, because a delete of a name that does not exist is an error the app
  # puts in the shade — one notification per name, every run.
  local leftover
  for leftover in harness-panel harness-save harness-one harness-new \
    inside-a inside-b gone-a gone-b harness-tile-a harness-tile-b \
    harness-tile-c; do
    case $saved in
      *"\"$leftover\""*) ;;
      *) continue ;;
    esac
    shell am start-foreground-service -n "$SERVICE" \
      -a org.phonelink.proxy.action.DELETE_PROFILE --es profile "$leftover" \
      >/dev/null 2>&1
  done
  sleep 1
  # The screen dumps the run made. uiautomator writes them on the card and
  # nothing removed them, so they outlived the run that asked for them; they
  # are asked for again here rather than trusted to the delete, because a card
  # that refuses the write is worth a check of its own.
  local dumps="" dump="" stable_after=""
  for dump in /sdcard/proxy-app-ui.xml /sdcard/proxy-app-shot.xml; do
    shell rm -f "$dump" >/dev/null 2>&1
    if shell ls "$dump" >/dev/null 2>&1; then
      dumps="$dumps $dump"
    fi
  done
  if [ -z "$dumps" ]; then
    ok "the run leaves no screen dumps on the phone's card"
  else
    bad "the run leaves no screen dumps on the phone's card"
    printf '  still there:%s\n' "$dumps"
  fi
  # The instance the phone lives on: the run installed and drove the test
  # package, so this one's listener and its store have to read as they did
  # before it started. Compared whole rather than field by field, because a
  # field that nobody thought to compare is exactly what a shared store would
  # change.
  if [ -n "${stable_before:-}" ]; then
    stable_after=$(shell dumpsys activity service "$STABLE/$CLASS.ProxyService" 2>/dev/null)
    if [ "$stable_before" = "$stable_after" ]; then
      ok "the daily proxy is untouched"
    else
      bad "the daily proxy is untouched"
      diff <(printf '%s\n' "$stable_before") <(printf '%s\n' "$stable_after") |
        head -12 | sed 's/^/  /'
    fi
  fi
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
  if [ "$partial" = 1 ]; then
    # Never TOTAL: the history compares full runs, and a filtered one that
    # looked like one would hide a step that was never asked for. The row still
    # says a run happened, what it cost and how it ended.
    timing_row PARTIAL "$total" "$pass" "$fail" partial
  else
    timing_row TOTAL "$total" "$pass" "$fail" \
      "$([ "$fail" -eq 0 ] && echo ok || echo failed)"
  fi
  if [ -n "${eta_state:-}" ]; then
    rm -f "$eta_state" "$eta_state.part"
  fi
  if [ -n "${eta_planned:-}" ] && [ "$eta_planned" -gt 0 ]; then
    printf 'eta %s taken, %s planned (%s)\n' \
      "$(eta_fmt "$(awk -v s="$total" 'BEGIN { printf "%d", s * 1000 }')")" \
      "$(eta_fmt "$eta_planned")" \
      "$(awk -v taken="$total" -v planned="$eta_planned" \
        'BEGIN { printf "%+.0f%%", (taken * 1000 - planned) * 100 / planned }')"
  fi
  printf 'timings: %s\n' "$TIMINGS"
  printf 'artifacts: %s\n' "$ARTIFACTS"
  printf '\n%d passed, %d failed\n' "$pass" "$fail"
  if [ "$partial" = 1 ]; then
    printf 'partial run: %d of %d steps (%s); no TOTAL row in timings.csv\n' \
      "$steps_run" "${#STEPS[@]}" "$only"
  fi
  if [ "$finished" = 1 ]; then
    # A run that reached its last step exits on what its checks said, which
    # includes the clock fit decided above; an interrupted one keeps the status
    # it already had.
    [ "$fail" -eq 0 ]
    exit $?
  fi
}
# An interrupted run finalises its recording too, or the phone keeps it.
trap cleanup EXIT
trap 'exit 130' INT TERM

# A start that replaces everything: a step about one configuration must not
# inherit a listener another step left behind, since several may run at once.
start_app() {
  shell am start-foreground-service -n "$SERVICE" -a "$STOP" >/dev/null 2>&1
  start_proxy --ei port "$PORT" --es user "$USER_NAME" --es password "$PASSWORD" \
    --ez anonymous false "$@"
}

# A start that adds: this configuration's listener, and whatever else runs.
# anonymous is pinned: a configuration a previous run left in the store must
# not turn the test's listener into an open relay.
start_proxy() {
  shell am start-foreground-service -n "$SERVICE" -a "$START" "$@" >/dev/null 2>&1
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
  shell am start -W -n "$ACTIVITY" >/dev/null 2>&1 || return 1
  settle
  # The class package is the same under either id, so the class name is what
  # the dump always shows: `pkg/.MainActivity` for the stable id, the full form
  # for the test one.
  shell dumpsys activity activities | grep -q "$CLASS.MainActivity" || return 1
  ! phone logcat -d -b crash 2>/dev/null | grep -q "$PKG"
}

# Whether a checkbox is ticked, scrolling down until it is on screen.
panel_checked() { # panel_checked ID -> yes|no
  local id=$1 node
  sequence "scroll-to id=$id 8000" || return 1
  node=$(ui_dump | tr '>' '\n' | grep "id/$id\"")
  [ -n "$node" ] || return 1
  case $node in
    *'checked="true"'*) printf 'yes\n' ;;
    *) printf 'no\n' ;;
  esac
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


# The panel's checks, run by the phone instead of looked at from a capture: one
# `am instrument` returns a status per claim, and every status becomes a check
# here, so the record of the run reads the same either way. A status without a
# verdict, or an instrumentation that never started, fails the step — silence
# is never a pass.
device_checks() { # device_checks FIRST SECOND
  local first=$1 second=$2 output line body key value
  local claim="" verdict="" detail="" seen=0
  output=$(phone shell am instrument -w -e first "$first" -e second "$second" \
    "$DEVICETEST_PKG/.PanelTests" 2>&1)
  while IFS= read -r line; do
    line=${line#"${line%%[![:space:]]*}"}
    case $line in
      INSTRUMENTATION_STATUS:\ *)
        body=${line#INSTRUMENTATION_STATUS: }
        key=${body%%=*}
        value=${body#*=}
        case $key in
          check) claim=$value ;;
          verdict) verdict=$value ;;
          detail) detail=$value ;;
        esac
        ;;
      INSTRUMENTATION_STATUS_CODE:*)
        if [ -n "$claim" ]; then
          if [ "$verdict" = pass ]; then
            ok "$claim"
          else
            bad "$claim" "$detail"
          fi
          seen=$((seen + 1))
        fi
        claim="" verdict="" detail=""
        ;;
    esac
  done <<<"$output"
  if [ "$seen" -eq 0 ]; then
    bad 'the phone runs the page checks' \
      "$(printf '%s\n' "$output" | head -2 | tr '\n' ' ')"
  fi
}


# Is the app on the Doze allowlist a boot restart needs?
battery_exempt() { shell cmd deviceidle whitelist | grep -q 'org.phonelink.proxy'; }


# The panel has a password field, and the phone's autofill service answers it
# with a "save this password?" sheet that takes the focus and would swallow the
# taps of the next step. It is off for the run and put back afterwards.
autofill_service=""


# Play Protect offers to send an app it does not know for a security check on
# install, and `adb install` waits for that answer — a run then hangs in its
# install step behind a dialog nobody can see. It is off for the run and put
# back afterwards.
verifier_setting=""


wait_foreground() {
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    foreground && return 0
    sleep 0.5
  done
  return 1
}

# Succeeds when a request through a tunnel reaches the internet.
through() { # through PORT USER PASSWORD
  local code
  code=$(curl -sS -m 15 -o /dev/null -w '%{http_code}' \
    --socks5-hostname "$2:$3@$ADDRESS:$1" "$TUNNEL_URL" 2>/dev/null) \
    || return 1
  [ "$code" = "200" ]
}

# Whose fault a failed tunnel is. The check knows only that curl did not get a
# 200: either the proxy dropped the request or the phone had nowhere to send
# it, and the second one is nothing this app can fix. So the phone is asked
# directly, with the proxy out of the path — its route by address, its resolver
# by name — and the answer goes where the failure is read: a line under the
# FAIL and a row in uplink.csv. Two adb calls and one logcat, paid only when a
# check fails, which is the run that has to be repeated otherwise.
uplink_diag() { # uplink_diag PORT
  local port=$1 host said ip reach literal iface egress_ip verdict
  local log_line log_lines counters report eg
  host=$(printf '%s' "$TUNNEL_URL" | sed -e 's|^[a-z]*://||' -e 's|[:/].*||')
  # An address is not a name: the second probe is then about reaching that
  # host, not about a resolver.
  case $host in
    '' | *[!0-9.]*) literal=no ;;
    *) literal=yes ;;
  esac
  # One dumpsys answers three questions: which network the app leaves by, what
  # the port moved, and what the service thinks it is doing.
  report=$(shell dumpsys activity service "$SERVICE" 2>/dev/null)
  # `dumpsys activity service` indents the service's own lines by four spaces,
  # and the dump's column is six spaces after the name; the width is what keeps
  # a Help sentence that starts with the word from being read as the answer.
  egress=$(printf '%s\n' "$report" | sed -n 's/^ *egress \{6\}//p' | head -1)
  counters=$(printf '%s\n' "$report" |
    sed -n 's/^ *running *//p' | grep -F "port $port" | head -1)
  case $egress in
    '' | none*) iface= ;;
    *) iface=$(printf '%s' "$egress" | sed -n 's/^\([^ ]*\) .*/\1/p') ;;
  esac
  # The phone's own default route, which is the Wi-Fi link here.
  said=$(shell "ping -c 1 -W 3 1.1.1.1" 2>&1)
  case $said in
    *" 1 received"*) ip=yes ;;
    *" 0 received"*) ip=no ;;
    *) ip=unknown ;;
  esac
  said=$(shell "ping -c 1 -W 3 $host" 2>&1)
  case $said in
    *" 1 received"*) reach=yes ;;
    *" 0 received"*) reach=no ;;
    *) reach=unknown ;;
  esac
  # And the route the tunnel actually takes: the app pins its egress to
  # cellular, so a ping that follows the default route says nothing about it.
  if [ -n "$iface" ]; then
    said=$(shell "ping -c 1 -W 3 -I $iface 1.1.1.1" 2>&1)
    case $said in
      *" 1 received"*) egress_ip=yes ;;
      *" 0 received"*) egress_ip=no ;;
      *) egress_ip=unknown ;;
    esac
  else
    egress_ip=none
  fi
  if [ "$egress_ip" = none ]; then
    case $egress in
      *waiting*) verdict="the app is still waiting for a cellular network, so the phone had none to give it" ;;
      *) verdict="the app holds no cellular egress, so the proxy had nowhere to send the request" ;;
    esac
  elif [ "$egress_ip" = no ]; then
    verdict="the app's egress ($iface) cannot reach 1.1.1.1: the proxy was given a request that network could not carry"
  elif [ "$ip" = no ]; then
    verdict="the app's egress ($iface) reaches the internet while the phone's default route does not: the proxy was fine"
  elif [ "$reach" = no ] && [ "$literal" = yes ]; then
    verdict="the app's egress ($iface) reaches the internet, but that address does not answer it: the check's own address was unreachable"
  elif [ "$reach" = no ]; then
    verdict="the app's egress ($iface) reaches the internet but $host does not answer: the check's own name was the suspect"
  else
    verdict="the app's egress ($iface) and the phone's route both work, so the proxy is the suspect"
  fi
  # The raw line first: a misparse then reads as one instead of as a verdict.
  printf '  uplink: the app reports its egress: %s\n' "${egress:-none in the dump}"
  printf '  uplink: %s\n' "$verdict"
  # What the port itself saw: bytes in and out say whether the request reached
  # the app at all, which the log line alone cannot.
  if [ -n "$counters" ]; then
    printf '  uplink: the app reports: %s\n' "$counters"
  fi
  # The app's last word about this port, an error line first: the last line may
  # be the start that worked, which explains nothing about the failure.
  log_lines=$(shell "logcat -d -s phone-link-proxy:V" 2>/dev/null |
    grep -F "port $port" | tail -20)
  log_line=$(printf '%s\n' "$log_lines" |
    grep -Ei 'refus|fail|error|timeout|unreachable|denied' | tail -1)
  [ -n "$log_line" ] || log_line=$(printf '%s\n' "$log_lines" | tail -1)
  if [ -n "$log_line" ]; then
    printf '  uplink: the app says: %s\n' "$(printf '%s' "$log_line" | sed 's/.*phone-link-proxy: //')"
  fi
  eg=${egress:-none}
  # The verdict has commas in it, so it is quoted: uplink.csv keeps six columns.
  printf '%s,%s,%s,%s,"%s","%s"\n' "$(now_ms)" "$port" "$ip" "$reach" "$eg" "$verdict" >>"$UPLINK"
}

# A check whose claim is a request through a tunnel: on failure it says whose
# fault it was, beside the claim that failed.
tunnel_check() { # tunnel_check CLAIM [PORT USER PASSWORD]
  local claim=$1
  if through "${2:-$PORT}" "${3:-$USER_NAME}" "${4:-$PASSWORD}"; then
    ok "$claim"
    return 0
  fi
  bad "$claim"
  uplink_diag "${2:-$PORT}"
}

through_proxy() { through "$PORT" "$USER_NAME" "$PASSWORD"; }

# Succeeds when a port refuses connections.
closed() { # closed PORT
  local status
  curl -sS -m 5 -o /dev/null --socks5-hostname "$ADDRESS:$1" \
    https://example.com >/dev/null 2>&1
  status=$?
  [ "$status" -eq 7 ]
}

port_closed() { closed "$PORT"; }

# One press of the Quick Settings tile: the shade has to be open for the click
# to land, and it stays open afterwards.
tile_click() {
  shell cmd statusbar expand-settings >/dev/null 2>&1
  sleep 2
  shell cmd statusbar click-tile "$PKG/$CLASS.ProxyTile" >/dev/null 2>&1
}

# Before the Wi-Fi read, because a dead link makes every read empty.
adb_link

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

# --- unlock
step_unlock() {
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

}

# --- install
step_install() {
  step 'install'
  # What the other instance looks like before this run touches the phone. Its
  # dump is empty when it is not installed or not running, and the check at the
  # end of the run is skipped then.
  stable_before=$(shell dumpsys activity service "$STABLE/$CLASS.ProxyService" 2>/dev/null)
  if phone install -r -g "$APK" >/dev/null 2>&1; then
    ok 'installs'
  else
    bad 'installs'
    printf '\n%d passed, %d failed\n' "$pass" "$fail"
    exit 1
  fi
  if phone install -r "$DEVICETEST_APK" >/dev/null 2>&1; then
    ok 'the on-device checks install'
  else
    bad 'the on-device checks install'
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


}

# --- panel
step_panel() {
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

}

# --- auto start
step_auto_start() {
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

}

# --- header warning
step_header_warning() {
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

}

# --- panel state
step_panel_state() {
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

}

# --- allowed network
step_allowed_network() {
  step 'allowed network'
  start_app --es ssid "$SSID" --ez any_network false
  if wait_foreground; then ok 'service is foreground'; else bad 'service is foreground'; fi
  tunnel_check 'request through the tunnel'
  if curl -sS -m 10 -o /dev/null --socks5-hostname \
    "$USER_NAME:wrong@$ADDRESS:$PORT" https://example.com >/dev/null 2>&1; then
    bad 'a wrong password is refused'
  else
    ok 'a wrong password is refused'
  fi

}

# --- anonymous from the panel
step_anonymous_from_the_panel() {
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
    tunnel_check 'and the credentials still work'
  else
    bad 'the panel controls are reachable'
  fi

}

# --- unrelated SSID
step_unrelated_ssid() {
  step 'unrelated SSID'
  start_app --es ssid "not-$SSID" --ez any_network false
  sleep 2
  if port_closed; then ok 'the port is closed'; else bad 'the port is closed'; fi
  if foreground; then ok 'the service keeps running while paused'; else
    bad 'the service keeps running while paused'
  fi

}

# --- predicate bypass
step_predicate_bypass() {
  step 'predicate bypass'
  start_app --es ssid "not-$SSID" --ez any_network true
  sleep 2
  tunnel_check 'any_network serves requests'

}

# --- profiles over adb
step_profiles_over_adb() {
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

}

# --- plain Save
step_plain_save() {
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

}

# --- card toggle
step_card_toggle() {
  step 'card toggle'
  # The card starts and stops a proxy by itself. What the words on it say while it
  # does that is checked on the phone, inside the app (step 'the page from the
  # inside'); what only the laptop can see is the listener: up after the press,
  # serving this proxy's credentials, and gone after the second one.
  start_app --es ssid "$SSID" --ez any_network false --ei port "$PORT"
  sleep 2
  save_profile harness-card
  shell am start-foreground-service -n "$SERVICE" -a "$STOP" >/dev/null 2>&1
  sleep 2
  open_panel
  if panel_home; then
    if card_toggle harness-card; then
      sleep 2
      if foreground; then ok 'the card starts that proxy'; else
        bad 'the card starts that proxy'
      fi
      tunnel_check 'and requests go through it'
      if card_toggle harness-card; then
        sleep 2
        if foreground; then bad 'a second press stops it'; else
          ok 'a second press stops it'
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

}

# --- rename
step_rename() {
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
  if watch_dump '"harness-adb"' 6000; then
    ok 'RENAME_PROFILE renames from adb'
  else
    bad 'RENAME_PROFILE renames from adb'
  fi
  if watch_dump 'profile *"harness-adb"' 3000; then
    ok 'and the proxy in use keeps its place'
  else
    bad 'and the proxy in use keeps its place'
  fi
  delete_profile_by_adb harness-adb

}

# --- info marks
step_info_marks() {
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

}

# --- new proxy
step_new_proxy() {
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

}

# --- ten proxies
step_ten_proxies() {
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
  # would reach it: the phone scrolls the list until it is there.
  if sequence 'scroll-to id=new_profile 10000'; then
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

}

# --- several at once
step_several_at_once() {
  step 'several at once'
  # The list is a list of listeners: two saved proxies, on two ports, with their
  # own credentials, both serving at the same time.
  PORT2=$((PORT + 1))
  USER2=phonelink-second
  PASSWORD2=phonelink-second-password
  start_app --es ssid "$SSID" --ez any_network false
  wait_foreground || true
  save_profile harness-a
  start_app --es ssid "$SSID" --ez any_network false --ei port "$PORT2" \
    --es user "$USER2" --es password "$PASSWORD2"
  wait_foreground || true
  save_profile harness-b
  shell am start-foreground-service -n "$SERVICE" -a "$STOP" >/dev/null 2>&1
  sleep 2
  shell am start-foreground-service -n "$SERVICE" -a "$START" \
    --es profile harness-a >/dev/null 2>&1
  sleep 2
  shell am start-foreground-service -n "$SERVICE" -a "$START" \
    --es profile harness-b >/dev/null 2>&1
  sleep 3
  failed_port=
  through "$PORT" "$USER_NAME" "$PASSWORD" || failed_port=$PORT
  [ -n "$failed_port" ] || through "$PORT2" "$USER2" "$PASSWORD2" ||
    failed_port=$PORT2
  if [ -z "$failed_port" ]; then
    ok 'two proxies serve at once'
  else
    bad 'two proxies serve at once'
    uplink_diag "$failed_port"
    shell dumpsys activity service "$SERVICE" | sed -n '/Right now/,/  saved/p'
  fi
  # Each one's own credentials, not the other's: the ports are not just both open.
  if through "$PORT" "$USER2" "$PASSWORD2"; then
    bad 'each proxy keeps its own credentials'
  else
    ok 'each proxy keeps its own credentials'
  fi
  # dumpsys indents a service's own lines by four spaces, so the block is taken
  # out first and the lines are matched without an anchor on the left.
  now=$(shell dumpsys activity service "$SERVICE" | sed -n '/Right now/,/  saved/p')
  running=$(printf '%s\n' "$now" | grep -c '^ *running')
  if [ "$running" -eq 2 ] &&
    printf '%s\n' "$now" | grep -q "\"harness-a\" · port $PORT " &&
    printf '%s\n' "$now" | grep -q "\"harness-b\" · port $PORT2 "; then
    ok 'dumpsys lists both, with their ports'
  else
    bad "dumpsys lists both, with their ports ($running listed)"
    shell dumpsys activity service "$SERVICE" | sed -n '/Right now/,/  saved/p'
  fi
  open_panel
  if panel_home; then
    if [ "$(card_state harness-a)" = Running ] &&
      [ "$(card_state harness-b)" = Running ]; then
      ok 'the list marks both of them running'
    else
      bad "the list marks both of them running ($(card_state harness-a)/$(card_state harness-b))"
      panel_where
    fi
  else
    bad 'the list is showing'
  fi
  # One by name, and the other is left alone.
  shell am start-foreground-service -n "$SERVICE" -a "$STOP" \
    --es profile harness-b >/dev/null 2>&1
  sleep 2
  if closed "$PORT2" && through "$PORT" "$USER_NAME" "$PASSWORD"; then
    ok 'a stop by name closes one port and leaves the other'
  else
    bad 'a stop by name closes one port and leaves the other'
  fi
  now=$(shell dumpsys activity service "$SERVICE" | sed -n '/Right now/,/  saved/p')
  remaining=$(printf '%s\n' "$now" | grep -c '^ *running')
  if [ "${remaining:-0}" -eq 1 ] &&
    printf '%s\n' "$now" | grep '^ *running' | grep -q "harness-a"; then
    ok 'and the one left is the one that was not named'
  else
    bad "and the one left is the one that was not named ($remaining listed)"
  fi
  shell am start-foreground-service -n "$SERVICE" -a "$STOP" >/dev/null 2>&1
  sleep 2
  if closed "$PORT" && closed "$PORT2" && ! foreground; then
    ok 'stop stops them all'
  else
    bad 'stop stops them all'
  fi
  delete_profile_by_adb harness-a
  delete_profile_by_adb harness-b

}

# --- deleting a proxy while it runs
step_deleting_a_proxy_while_it_runs() {
  step 'deleting a proxy while it runs'
  # A saved proxy is its listener's name, so deleting it has to take the listener
  # with it: a port the list cannot show is a port the panel cannot stop. Both
  # ways of deleting one — over adb and from the menu — have to end the same.
  PORT5=$((PORT + 4))
  PORT6=$((PORT + 5))
  start_app --es ssid "$SSID" --ez any_network false --ei port "$PORT5"
  sleep 2
  save_profile gone-a
  start_app --es ssid "$SSID" --ez any_network false --ei port "$PORT6" \
    --es user "$USER2" --es password "$PASSWORD2"
  sleep 2
  save_profile gone-b
  shell am start-foreground-service -n "$SERVICE" -a "$START" \
    --es profile gone-a >/dev/null 2>&1
  sleep 2
  shell am start-foreground-service -n "$SERVICE" -a "$START" \
    --es profile gone-b >/dev/null 2>&1
  sleep 3
  if through "$PORT5" "$USER_NAME" "$PASSWORD" &&
    through "$PORT6" "$USER2" "$PASSWORD2"; then
    ok 'both serve before one of them is deleted'
  else
    bad 'both serve before one of them is deleted'
  fi
  delete_profile_by_adb gone-a
  if closed "$PORT5" && through "$PORT6" "$USER2" "$PASSWORD2"; then
    ok 'deleting a running proxy over adb closes its port and leaves the other'
  else
    bad 'deleting a running proxy over adb closes its port and leaves the other'
  fi
  now=$(shell dumpsys activity service "$SERVICE" | sed -n '/Right now/,/  saved/p')
  if [ "$(printf '%s\n' "$now" | grep -c '^ *running')" -eq 1 ] &&
    printf '%s\n' "$now" | grep '^ *running' | grep -q gone-b; then
    ok 'and the service reports only the one that is left'
  else
    bad 'and the service reports only the one that is left'
    shell dumpsys activity service "$SERVICE" | sed -n '/Right now/,/  saved/p'
  fi
  # The menu's Delete, on the other running one: the panel stops it and goes back
  # to the list, where its card is gone.
  open_panel
  if panel_open gone-b; then
    if menu_pick Delete && sequence \
      'wait id=button1 2000; tap-id button1 3000; wait id=new_profile 3000'; then
      sleep 2
      if closed "$PORT6" && ! foreground; then
        ok "the menu's Delete stops the proxy it deletes"
      else
        bad "the menu's Delete stops the proxy it deletes"
      fi
      if shell dumpsys activity service "$SERVICE" | grep 'saved' | grep -q '"gone-b"'; then
        bad 'and the store no longer has it'
      else
        ok 'and the store no longer has it'
      fi
    else
      bad 'the menu offers Delete'
      panel_where
    fi
  else
    bad 'the running proxy to delete opens'
    panel_where
  fi

}

# --- the page from the inside
step_the_page_from_the_inside() {
  step 'the page from the inside'
  # The same claims about the page and the cards, decided where the views are.
  # An instrumentation starts the app's process again, so this runs with nothing
  # listening and starts what it needs from the page itself; the port stays the
  # laptop's business, and the step before this one is where it is proven.
  PORT3=$((PORT + 2))
  PORT4=$((PORT + 3))
  start_app --es ssid "$SSID" --ez any_network false --ei port "$PORT3" \
    --es user "$USER_NAME" --es password "$PASSWORD"
  wait_foreground || true
  save_profile inside-a
  start_app --es ssid "$SSID" --ez any_network false --ei port "$PORT4" \
    --es user "$USER2" --es password "$PASSWORD2"
  wait_foreground || true
  save_profile inside-b
  shell am start-foreground-service -n "$SERVICE" -a "$STOP" >/dev/null 2>&1
  sleep 2
  device_checks inside-a inside-b
  delete_profile_by_adb inside-a
  delete_profile_by_adb inside-b

}

# --- proxy log
step_proxy_log() {
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

}

# --- stop
step_stop() {
  step 'stop'
  shell am start-foreground-service -n "$SERVICE" -a "$STOP" >/dev/null 2>&1
  sleep 2
  if foreground; then bad 'stop leaves no service'; else ok 'stop leaves no service'; fi
  if port_closed; then ok 'the port is closed after stop'; else bad 'the port is closed after stop'; fi

}

# --- tile
step_tile() {
  step 'tile'
  if unlock_phone; then :; fi
  if keyguard_showing; then
    printf 'SKIP the tile: the shade ignores clicks while the phone is locked\n'
  else
    # Every question here is answered by the service's own view of the store,
    # and the step before this one left the service stopped: a start first.
    start_app --es ssid "$SSID" --ez any_network false
    sleep 2

    # An earlier run may have left the tile's own settings changed, so they go
    # back to the narrow default before anything is asked: this step decides
    # what the tile is.
    shell cmd statusbar collapse >/dev/null 2>&1
    sleep 1
    open_panel
    menu_pick 'The tile' &&
      sequence 'tap-id start_tile 3000; tap-id stop_tile 3000; tap-id button1 3000'
    sleep 1
    if shell dumpsys activity service "$SERVICE" 2>/dev/null |
      grep -q 'tile_start  tile' &&
      shell dumpsys activity service "$SERVICE" 2>/dev/null |
      grep -q 'tile_stop   tile'; then
      ok 'the tile settings go back to their narrow default'
    else
      bad 'the tile settings go back to their narrow default'
    fi

    # The cycle is empty until one is asked for, and a run that died before its
    # untick would leave it on: the store says which box is ticked, so each
    # visit clears one. Nothing to clear is the common case and costs no visit.
    for attempt in 1 2 3; do
      cycle=$(shell dumpsys activity service "$SERVICE" 2>/dev/null |
        sed -n 's/^ *tile_cycle  *//p' | head -1)
      case ",$cycle," in
        *,tile,*) box=cycle_tile ;;
        *,in_use,*) box=cycle_in_use ;;
        *,all,*) box=cycle_all ;;
        *) box="" ;;
      esac
      [ -n "$box" ] || break
      if open_panel && menu_pick 'The tile' && panel_tap "$box"; then :; fi
      back >/dev/null 2>&1
      settle
    done
    if shell dumpsys activity service "$SERVICE" 2>/dev/null |
      grep -q 'tile_cycle  none'; then
      ok 'the tile has no cycle until one is asked for'
    else
      bad 'the tile has no cycle until one is asked for'
    fi

    # Nothing is on the tile, so it is the switch it always was: a click starts
    # the configuration the last start stored, and the next one stops
    # everything.
    shell am start-foreground-service -n "$SERVICE" -a "$STOP" >/dev/null 2>&1
    sleep 2
    shell cmd statusbar add-tile "$PKG/$CLASS.ProxyTile" >/dev/null 2>&1
    tile_click
    if wait_foreground; then ok 'the tile starts the service'; else
      bad 'the tile starts the service'
    fi
    if through_proxy; then ok 'the tile start serves requests'; else
      bad 'the tile start serves requests'
    fi
    if shell dumpsys activity service "$SERVICE" | grep -q 'tile  *nothing bound'; then
      ok 'with nothing on it, the tile says so'
    else
      bad 'with nothing on it, the tile says so'
    fi
    tile_click
    sleep 3
    if foreground; then bad 'the tile stops the service'; else
      ok 'the tile stops the service'
    fi
    if port_closed; then ok 'the tile stop closes the port'; else
      bad 'the tile stop closes the port'
    fi

    # Two proxies on the tile: one click starts both, the next stops both, and a
    # proxy that is not on the tile keeps doing what it was doing.
    PORT_T1=$((PORT + 1))
    PORT_T2=$((PORT + 2))
    PORT_T3=$((PORT + 3))
    start_app --es ssid "$SSID" --ez any_network false --ei port "$PORT_T1"
    sleep 2
    save_profile harness-tile-a
    start_app --es ssid "$SSID" --ez any_network false --ei port "$PORT_T2"
    sleep 2
    save_profile harness-tile-b
    # The two proxies go on the tile from the tile's own page, which is where
    # the start and stop sides live too: one visit, one place, and the store is
    # what decides whether a question about the binding passed.
    shell cmd statusbar collapse >/dev/null 2>&1
    sleep 1
    bound_ok=no
    if open_panel && menu_pick 'The tile' &&
      sequence 'tap-scroll "text=harness-tile-a" 4000; tap-scroll "text=harness-tile-b" 4000; tap-id button1 3000'; then
      sleep 1
      if shell dumpsys activity service "$SERVICE" |
        grep -q 'tile  .*harness-tile-a.*harness-tile-b'; then
        bound_ok=yes
      fi
    fi
    if [ "$bound_ok" = yes ]; then
      ok 'a proxy says it belongs on the tile'
    else
      bad 'a proxy says it belongs on the tile'
      panel_where
    fi
    on_tile=$(shell dumpsys activity service "$SERVICE" | sed -n 's/^ *tile  *//p' | head -1)
    case $on_tile in
      *harness-tile-a*harness-tile-b*) ok 'dumpsys names both of them on the tile' ;;
      *) bad "dumpsys names both of them on the tile ($on_tile)" ;;
    esac
    shell am start-foreground-service -n "$SERVICE" -a "$STOP" >/dev/null 2>&1
    sleep 2
    tile_click
    sleep 3
    if through "$PORT_T1" "$USER_NAME" "$PASSWORD" &&
      through "$PORT_T2" "$USER_NAME" "$PASSWORD"; then
      ok 'one click starts both proxies on the tile'
    else
      bad 'one click starts both proxies on the tile'
    fi
    tile_click
    sleep 3
    if closed "$PORT_T1" && closed "$PORT_T2" && ! foreground; then
      ok 'and the next click stops them both'
    else
      bad 'and the next click stops them both'
    fi

    # A third proxy that is not on the tile: the tile starts and stops its own
    # and leaves this one where it is.
    start_app --es ssid "$SSID" --ez any_network false --ei port "$PORT_T3"
    sleep 2
    save_profile harness-tile-c
    shell am start-foreground-service -n "$SERVICE" -a "$START" \
      --es profile harness-tile-c >/dev/null 2>&1
    sleep 3
    tile_click
    sleep 3
    if through "$PORT_T1" "$USER_NAME" "$PASSWORD" &&
      through "$PORT_T3" "$USER_NAME" "$PASSWORD"; then
      ok 'a proxy that is not on the tile is left as it is'
    else
      bad 'a proxy that is not on the tile is left as it is'
    fi
    tile_click
    sleep 3
    if closed "$PORT_T1" && closed "$PORT_T2" &&
      through "$PORT_T3" "$USER_NAME" "$PASSWORD"; then
      ok 'and stopping the tile leaves it alone'
    else
      bad 'and stopping the tile leaves it alone'
    fi

    # The tile's page is in the menu, not behind a long press: Android's long
    # press is App info, which is where a user looks for the app itself. What
    # the radios store is read out of the service's own view of the store, so a
    # start goes first — the last click left everything stopped.
    start_app --es ssid "$SSID" --ez any_network false
    sleep 2
    # The shade is still down from the clicks, so it goes before the panel can
    # be touched.
    shell cmd statusbar collapse >/dev/null 2>&1
    sleep 1
    open_panel
    if menu_pick 'The tile' && wait_for 'A click while the tile is off starts' 2000; then
      ok "the menu offers the tile's own page"
      if ui_dump | grep -q 'id/start_all"' && ui_dump | grep -q 'id/stop_all"'; then
        ok 'the page has a start side and a stop side'
      else
        bad 'the page has a start side and a stop side'
      fi
      if panel_tap stop_all; then
        # The radios store as they are tapped, so the service's own view of the
        # tile says what the next click will stop.
        sleep 1
        stop_scope=$(shell dumpsys activity service "$SERVICE" |
          sed -n 's/^ *tile_stop  *//p' | head -1)
        if [ "$stop_scope" = all ]; then
          ok 'a radio stores what a click stops'
        else
          bad "a radio stores what a click stops ($stop_scope)"
        fi
      else
        bad 'the stop side can be chosen'
      fi
      if panel_tap cycle_all && sleep 1 &&
        shell dumpsys activity service "$SERVICE" |
        grep -q 'tile_cycle  all'; then
        ok 'a cycle asks for every saved proxy between the two ends'
      else
        bad 'a cycle asks for every saved proxy between the two ends'
      fi
      back >/dev/null 2>&1
      settle
    else
      bad "the menu offers the tile's page"
      panel_where
    fi

    # Three presses now: the tile's own set, then the set the cycle adds, then
    # the stop side. The third proxy is saved but not on the tile, so the second
    # press is the only one that starts it — and the first must not, or the
    # press before it already meant everything.
    shell am start-foreground-service -n "$SERVICE" -a "$STOP" >/dev/null 2>&1
    sleep 2
    tile_click
    sleep 3
    if through "$PORT_T1" "$USER_NAME" "$PASSWORD" &&
      through "$PORT_T2" "$USER_NAME" "$PASSWORD" && closed "$PORT_T3"; then
      ok "the first press is the tile's own set"
    else
      bad "the first press is the tile's own set"
    fi
    tile_click
    sleep 3
    if through "$PORT_T3" "$USER_NAME" "$PASSWORD" &&
      through "$PORT_T1" "$USER_NAME" "$PASSWORD" &&
      through "$PORT_T2" "$USER_NAME" "$PASSWORD"; then
      ok 'the second press adds the set the cycle names and starts only what is missing'
    else
      bad 'the second press adds the set the cycle names and starts only what is missing'
    fi
    tile_click
    sleep 3
    if closed "$PORT_T1" && closed "$PORT_T2" && closed "$PORT_T3" && ! foreground; then
      ok 'the third press is the stop side'
    else
      bad 'the third press is the stop side'
    fi

    # The cycle goes back to empty, so the tile the next run meets has the two
    # states it always had. The store answers while the service runs, so a
    # start goes first.
    start_app --es ssid "$SSID" --ez any_network false
    sleep 2
    shell cmd statusbar collapse >/dev/null 2>&1
    sleep 1
    if open_panel && menu_pick 'The tile' && panel_tap cycle_all; then
      sleep 1
      if shell dumpsys activity service "$SERVICE" | grep -q 'tile_cycle  none'; then
        ok 'unticking the cycle leaves the tile with two states again'
      else
        bad 'unticking the cycle leaves the tile with two states again'
      fi
      back >/dev/null 2>&1
      settle
    else
      bad 'unticking the cycle leaves the tile with two states again'
      panel_where
    fi

    shell am start-foreground-service -n "$SERVICE" -a "$STOP" >/dev/null 2>&1
    delete_profile_by_adb harness-tile-a
    delete_profile_by_adb harness-tile-b
    delete_profile_by_adb harness-tile-c
    shell cmd statusbar collapse >/dev/null 2>&1
  fi
}

# --- the steps, in the order a full run takes them ------------------------

# Every step a full run takes, by the name the log prints. A step is a function
# named after itself (`card toggle` is `step_card_toggle`), which is what makes
# PHONE_LIVE_ONLY possible: the loop at the bottom calls the ones asked for.
STEPS=(
  'unlock' 'install' 'panel' 'auto start' 'header warning' 'panel state'
  'allowed network' 'anonymous from the panel' 'unrelated SSID'
  'predicate bypass' 'profiles over adb' 'plain Save' 'card toggle' 'rename'
  'info marks' 'new proxy' 'ten proxies' 'several at once'
  'deleting a proxy while it runs' 'the page from the inside' 'proxy log'
  'stop' 'tile'
)

step_function() { # step_function 'card toggle' -> step_card_toggle
  printf 'step_%s' "$(printf '%s' "$1" | tr ' A-Z' '_a-z')"
}

# Whether the run was asked for this step by name; a full run asks for all.
wanted() { # wanted NAME
  [ -n "$only" ] || return 0
  local want
  for want in ${only//,/ }; do
    [ "$want" = "$1" ] && return 0
  done
  return 1
}

# The three things a step may lean on: the phone awake, the app installed, and
# one proxy saved under the name a page opens by (`harness-panel`). The first
# two are steps of their own; the third is this, and it is what a filtered run
# does between them.
preamble() {
  start_app --es ssid "$SSID" --ez any_network false --ei port "$PORT"
  sleep 2
  save_profile harness-panel
}

only=${PHONE_LIVE_ONLY:-}
steps_run=0
# The names are split by commas and nothing else, because a step's name has
# spaces in it; a comma around each one makes the membership test a `case`.
only_list=""

# Whether the run was asked for this step; a full run asks for all of them.
wanted() { # wanted NAME
  [ -n "$only" ] || return 0
  case $only_list in
    *",$1,"*) return 0 ;;
  esac
  return 1
}

if [ -n "$only" ]; then
  partial=1
  only_list=",$(printf '%s' "$only" | sed 's/^ *//; s/ *$//; s/ *, */,/g'),"
  # A name no step answers to would otherwise run nothing and still look green,
  # so the names asked for have to be exactly the steps that answer to them.
  asked_count=$(($(printf '%s' "$only_list" | grep -o ',' | wc -l) - 1))
  matched=0
  for each in "${STEPS[@]}"; do
    wanted "$each" && matched=$((matched + 1))
  done
  if [ "$matched" -ne "$asked_count" ]; then
    printf 'no step is called one of "%s"; the steps are:\n' "$only" >&2
    printf '  %s\n' "${STEPS[@]}" >&2
    exit 2
  fi
  printf 'a partial run: only %s, and the preamble every step assumes\n' "$only"
fi

# What this run should cost, priced before the first step: the steps the loop
# below will take, each at the median of its last runs. A filtered run pays for
# the steps it asked for and not for the whole suite.
if [ "$eta_on" = 1 ]; then
  ETA_ORDER=()
  for planned_step in "${STEPS[@]}"; do
    case $planned_step in
      unlock | install) ;;
      *)
        wanted "$planned_step" || continue
        ;;
    esac
    ETA_ORDER+=("$planned_step")
  done
  eta_load "$TIMINGS" "${PHONE_LIVE_ETA_RUNS:-5}"
  declare -A ETA_EST=()
  eta_borrowed=$(eta_fallback)
  for planned_step in "${ETA_ORDER[@]}"; do
    ETA_EST[$planned_step]=${ETA_MEDIAN[$planned_step]:-$eta_borrowed}
    ETA_EST[$planned_step]=${ETA_EST[$planned_step]:-0}
  done
  eta_plan "${ETA_ORDER[@]}"
  eta_planned=$ETA_PLAN_MS
  eta_state=$(mktemp)
  ETA_STATE=$eta_state
  eta_ticker "$eta_state" "$eta_every" &
  eta_pid=$!
fi

# The loop keeps its own name: a step's body is free to use `name` for its own
# loops, and a variable a step clobbers must not be what decides the next step.
for wanted_step in "${STEPS[@]}"; do
  if [ -n "$only" ]; then
    # The preamble runs whatever was asked for; everything else only if it was.
    case $wanted_step in
      unlock | install) ;;
      *)
        wanted "$wanted_step" || continue
        ;;
    esac
  fi
  steps_run=$((steps_run + 1))
  "$(step_function "$wanted_step")"
  if [ -n "$only" ] && [ "$wanted_step" = install ]; then
    preamble
  fi
done

# The verdict is printed by cleanup, after the last check — the clock fit is
# decided there, and a summary printed here could say "0 failed" and then fail
# a moment later.
finished=1
