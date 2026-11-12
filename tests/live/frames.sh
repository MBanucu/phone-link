#!/usr/bin/env bash
# Stills out of a run's screen recording: the point of keeping the mp4 is that
# any moment of a run can be looked at afterwards, long after the run.
#
#   tests/live/frames.sh result-live/<run>/screen.mp4 12.5 0:45 1:02.25
#
# Each time is seconds (12.5), mm:ss or hh:mm:ss. The stills land next to the
# recording as screen-<time>.png, or in the directory given with -o. ffmpeg is
# expected on the host already (nixpkgs.ffmpeg); PHONE_LIVE_FFMPEG overrides.
set -eu

usage() {
  printf 'usage: %s [-o DIR] RECORDING AT [AT...]\n' "${0##*/}" >&2
  printf '  AT is seconds (12.5), mm:ss or hh:mm:ss\n' >&2
  exit 2
}

ffmpeg=${PHONE_LIVE_FFMPEG:-}
if [ -z "$ffmpeg" ]; then
  ffmpeg=$(command -v ffmpeg 2>/dev/null || true)
fi
if [ -z "$ffmpeg" ] && [ -x /run/current-system/sw/bin/ffmpeg ]; then
  ffmpeg=/run/current-system/sw/bin/ffmpeg
fi

out=""
while [ $# -gt 0 ]; do
  case $1 in
    -o)
      [ $# -ge 2 ] || usage
      out=$2
      shift 2
      ;;
    -h | --help) usage ;;
    --) shift && break ;;
    -*) usage ;;
    *) break ;;
  esac
done

recording=${1:-}
[ -n "$recording" ] || usage
shift
[ $# -gt 0 ] || usage
[ -n "$ffmpeg" ] || {
  printf 'no ffmpeg: install it, set PHONE_LIVE_FFMPEG, or use nix-shell -p ffmpeg\n' >&2
  exit 1
}
[ -f "$recording" ] || {
  printf 'no such recording: %s\n' "$recording" >&2
  exit 1
}

[ -n "$out" ] || out=$(dirname "$recording")
mkdir -p "$out"

# seconds out of what a human would write for a moment in a run
to_seconds() {
  printf '%s\n' "$1" | awk -F: '
    NF == 1 { print $1; exit }
    NF == 2 { print $1 * 60 + $2; exit }
    NF == 3 { print $1 * 3600 + $2 * 60 + $3; exit }
    { exit 1 }'
}

status=0
for at in "$@"; do
  seconds=$(to_seconds "$at") || {
    printf 'not a time: %s\n' "$at" >&2
    status=1
    continue
  }
  name=$(printf '%s' "$at" | tr ':.' '--')
  frame="$out/screen-$name.png"
  # -ss before -i seeks fast; one frame is all a still is.
  if ! "$ffmpeg" -nostdin -loglevel error -y -ss "$seconds" -i "$recording" \
    -frames:v 1 -q:v 2 "$frame"; then
    printf 'no frame at %s (past the end of the recording?)\n' "$at" >&2
    status=1
    continue
  fi
  printf '%s\n' "$frame"
done
exit "$status"
