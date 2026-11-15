#!/usr/bin/env bash
# Ties the phone's clock to a run's screen recording.
#
#   tests/live/clock.sh [--radius S] RUN_DIR
#
# RUN_DIR holds screen.mp4, the run's recording, and clock.csv, one line per
# flash edge written by the capture service (device_ns,wall_ms,on|off). The
# phone paints the screen the flash colour at instants it writes down, at the
# start of the run and at its end; this finds those flashes in the video and
# fits a line through them, which is what turns "the phone did this at
# 812345678901234" into "that is 12.345 s into the recording".
#
# Finding them takes two searches, because the recording has neither a known
# beginning nor a known end in the phone's time: screenrecord starts when it
# starts, and it only encodes a screen that changes, so the last frame can be
# seconds after the last flash. The first burst is looked for from the top of
# the file — the run flashes as soon as its recorder is up, so it is in the
# first seconds — and every later burst is predicted from where the first one
# turned out to be, which is exact to milliseconds over any run.
#
# A window can hold more than the burst it was opened for: on a short run both
# calibrations happen while the recorder is still going, four seconds apart, and
# a window wide enough to find the first burst also catches the second one. So
# the flashes found in the window are split into runs separated by a second of
# quiet — the same rule the phone's own record is split by — and the run with
# this burst's number of flashes, nearest where it was expected, is the one.
#
# It prints one line and writes RUN_DIR/clock.txt with the mapping
#
#   video_seconds = offset_s + drift * (device_ns - ref_ns) / 1e9
#
# fit_ms is what the mapping is worth: the spread of the per-edge errors over
# the number of edges. A run whose fit_ms is above about 10 has a clock problem;
# the phone and the recording are not the same timeline. worst_edge_ms is the
# largest single error, which is a property of that one flash — up to half a
# frame because the screen only changes 60 times a second, more when the encoder
# was busy with an animation and skipped the frame the colour appeared in.
#
# ffmpeg and ffprobe are expected on the host (nixpkgs.ffmpeg); PHONE_LIVE_FFMPEG
# overrides. Exit status is 0 only when every flash was found and the fit has
# an edge per flash.
set -eu

usage() {
  printf 'usage: %s [--radius S] RUN_DIR\n' "${0##*/}" >&2
  exit 2
}

radius=2
while [ $# -gt 0 ]; do
  case $1 in
    --radius)
      [ $# -ge 2 ] || usage
      radius=$2
      shift 2
      ;;
    -h | --help) usage ;;
    --) shift && break ;;
    -*) usage ;;
    *) break ;;
  esac
done

dir=${1:-}
[ -n "$dir" ] || usage

recording=$dir/screen.mp4
edges=$dir/clock.csv
[ -f "$recording" ] || {
  printf 'no recording at %s\n' "$recording" >&2
  exit 1
}
[ -f "$edges" ] || {
  printf 'no flash edges at %s\n' "$edges" >&2
  exit 1
}

ffmpeg=${PHONE_LIVE_FFMPEG:-}
if [ -z "$ffmpeg" ]; then
  ffmpeg=$(command -v ffmpeg 2>/dev/null || true)
fi
if [ -z "$ffmpeg" ] && [ -x /run/current-system/sw/bin/ffmpeg ]; then
  ffmpeg=/run/current-system/sw/bin/ffmpeg
fi
if [ -z "$ffmpeg" ]; then
  printf 'no ffmpeg: install it, set PHONE_LIVE_FFMPEG, or use nix-shell -p ffmpeg\n' >&2
  exit 1
fi
ffprobe=${PHONE_LIVE_FFPROBE:-}
if [ -z "$ffprobe" ]; then
  ffprobe=$(command -v ffprobe 2>/dev/null || true)
fi
if [ -z "$ffprobe" ] && [ -x /run/current-system/sw/bin/ffprobe ]; then
  ffprobe=/run/current-system/sw/bin/ffprobe
fi
if [ -z "$ffprobe" ]; then
  ffprobe=$(dirname "$ffmpeg")/ffprobe
fi
[ -x "$ffprobe" ] || {
  printf 'no ffprobe next to %s\n' "$ffmpeg" >&2
  exit 1
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

duration=$("$ffprobe" -v error -show_entries format=duration -of csv=p=0 \
  "$recording" 2>/dev/null | head -1)
[ -n "$duration" ] || {
  printf 'cannot read the length of %s\n' "$recording" >&2
  exit 1
}

# The flashes the phone wrote down, grouped into bursts. Inside a burst the
# edges are held 200 ms apart — a second when the phone was busy, which is why
# the gap that ends one is 2.5 s: the run's two calibrations are four seconds
# apart at the least, and a gap that wide is a different burst.
awk -F, -v gap=2500 '
  NR == 1 { next }
  NF >= 3 && $1 ~ /^[0-9]+$/ {
    if (!started || $2 - last > gap) burst++
    started = 1
    last = $2
    printf "%d,%s,%s,%s\n", burst, $1, $2, $3
  }' "$edges" >"$tmp/edges"
[ -s "$tmp/edges" ] || {
  printf 'no flash edges in %s\n' "$edges" >&2
  exit 1
}

# The frames of a window, as "pts,state" lines: state is on while the flash
# colour fills the screen. The colour is read where the decoder leaves it, in
# YUV: a full screen of the flash's magenta averages about y=75 u=215 v=229,
# while the panel's dark blues and this phone's wallpaper sit near u=156 v=129,
# so both chroma planes have to be far up to count — a bright, saturated purple
# screen is what would fool it, and this harness never draws one.
window_edges() { # window_edges START LEN -> "pts,on|off" per transition
  "$ffmpeg" -nostdin -hide_banner -loglevel info -ss "$1" -copyts -t "$2" \
    -i "$recording" -vf scale=1:1:flags=area,showinfo -f null - 2>"$tmp/ffmpeg.log" ||
    return 1
  awk '
    /pts_time:/ {
      t = ""
      if (match($0, /pts_time:[0-9.]+/)) {
        t = substr($0, RSTART + 9, RLENGTH - 9)
      }
      if (t == "" || !match($0, /mean:\[[0-9]+ [0-9]+ [0-9]+\]/)) {
        next
      }
      split(substr($0, RSTART + 6, RLENGTH - 7), mean, " ")
      on = (mean[2] > 195 && mean[3] > 200) ? 1 : 0
      if (seen && on != previous) {
        print t "," (on ? "on" : "off")
      }
      previous = on
      seen = 1
    }' "$tmp/ffmpeg.log"
}

# The runs of flashes in a window, the way the phone's record is split: 2.5 s
# of quiet between flashes starts a new one. Prints the run that has
# WANT flashes and starts nearest GUESS (an empty guess means the first), and
# leaves the sizes it saw in SIZES so a failure can say what was there.
burst_group() { # burst_group WANT GUESS SIZES <"t,state"
  awk -F, -v want="$1" -v guess="$2" -v sizes="$3" '
    {
      if (!seen || $1 - last > 2.5) {
        runs++
        first[runs] = $1
        size[runs] = 0
      }
      seen = 1
      last = $1
      text[++n] = $0
      run[n] = runs
      size[runs]++
    }
    END {
      best = 0
      for (i = 1; i <= runs; i++) {
        printf "%d%s", size[i], (i == runs ? ORS : " ") >sizes
        if (size[i] != want) continue
        spread = first[i] - guess
        if (spread < 0) spread = -spread
        if (!best || spread < nearest) {
          best = i
          nearest = spread
        }
      }
      close(sizes)
      if (!best) exit 1
      for (j = 1; j <= n; j++) {
        if (run[j] == best) print text[j]
      }
    }'
}

# The window is clipped to the file: a burst at either end of a run is half
# outside it, and asking ffmpeg for the part before the first frame would just
# come back empty.
clip() { # clip START LEN -> "start length" inside the recording
  awk -v s="$1" -v l="$2" -v d="$duration" 'BEGIN {
    if (s < 0) { l += s; s = 0 }
    if (s + l > d) l = d - s
    if (l < 0) l = 0
    printf "%.3f %.3f", s, l }'
}

pairs="$tmp/pairs"
: >"$pairs"
anchor_pts=""
anchor_ns=""
for burst in $(cut -d, -f1 "$tmp/edges" | uniq); do
  awk -F, -v b="$burst" '$1 == b { print $2 "," $3 "," $4 }' "$tmp/edges" \
    >"$tmp/device-$burst"
  want=$(wc -l <"$tmp/device-$burst")
  host=$(head -1 "$tmp/device-$burst" | cut -d, -f1)
  picked=no
  if [ -z "$anchor_pts" ]; then
    # The run's first burst: it is in the first seconds of the file, and how
    # many that is depends on when the recorder got going, so the window opens
    # where it is cheap and widens only when the flash is not there.
    guess=0
    for edge in 4 12 30; do
      read -r start length <<EOF
$(clip 0 "$edge")
EOF
      window_edges "$start" "$length" >"$tmp/raw-$burst" || true
      if burst_group "$want" "$guess" "$tmp/sizes-$burst" \
        <"$tmp/raw-$burst" >"$tmp/video-$burst"; then
        picked=yes
        break
      fi
    done
  else
    # A later burst, placed by the first one: over the minutes between them a
    # clock that is right to milliseconds cannot have moved the mapping by
    # more than that, so this window is small.
    guess=$(awk -v a="$anchor_pts" -v an="$anchor_ns" -v n="$host" \
      'BEGIN { printf "%.3f", a + (n - an) / 1e9 }')
    for edge in "$radius" 6 20; do
      read -r start length <<EOF
$(clip "$(awk -v g="$guess" -v r="$edge" 'BEGIN { print g - r }')" \
        "$(awk -v r="$edge" 'BEGIN { print 2 * r }')")
EOF
      window_edges "$start" "$length" >"$tmp/raw-$burst" || true
      if burst_group "$want" "$guess" "$tmp/sizes-$burst" \
        <"$tmp/raw-$burst" >"$tmp/video-$burst"; then
        picked=yes
        break
      fi
    done
  fi
  if [ "$picked" = no ]; then
    printf 'burst %s: %s flashes in the phone'"'"'s record, the recording has runs of %s\n' \
      "$burst" "$want" "$(cat "$tmp/sizes-$burst" 2>/dev/null || printf 'nothing')" >&2
    printf '  (a run is a set of flashes less than a second apart; the phone put\n' >&2
    printf '   this one at %s s of %s, so did the recorder start late?)\n' \
      "$guess" "$duration" >&2
    exit 1
  fi
  # On/off/on/off is the same shape for every burst, so matching the states
  # proves nothing about *which* burst was found. The time the flashes span
  # does: the phone wrote down how long its burst lasted, and the run found in
  # the recording has to last about as long.
  device_span=$(awk -F, 'NR == 1 { first = $2 } END { printf "%.3f", ($2 - first) / 1000 }' \
    "$tmp/device-$burst")
  video_span=$(awk -F, 'NR == 1 { first = $1 } END { printf "%.3f", $1 - first }' \
    "$tmp/video-$burst")
  awk -v b="$burst" -v d="$device_span" -v v="$video_span" 'BEGIN {
    spread = d - v
    if (spread < 0) spread = -spread
    if (spread <= 0.25) exit 0
    printf "burst %s: %s s in the record, %s s in the recording\n", b, d, v
    printf "  (that is not the same burst; the recorder may have started late)\n"
    exit 1 }' || exit 1
  paste -d, "$tmp/device-$burst" "$tmp/video-$burst" |
    awk -F, '
      $3 != $5 {
        printf "burst %s: the %dth flash is %s in the record and %s in the video\n",
          "'"$burst"'", NR, $3, $5 >"/dev/stderr"
        exit 1
      }
      { print $1, $4 }' >>"$pairs" || exit 1
  if [ -z "$anchor_pts" ]; then
    anchor_ns=$(head -1 "$pairs" | cut -d' ' -f1)
    anchor_pts=$(head -1 "$pairs" | cut -d' ' -f2)
  fi
done

ref=$(head -1 "$pairs" | cut -d' ' -f1)
awk -v ref="$ref" '
  { n++; x[n] = ($1 - ref) / 1e9; y[n] = $2; sx += x[n]; sy += y[n] }
  END {
    if (n < 2) {
      print "need at least two flashes to fit a clock" >"/dev/stderr"
      exit 1
    }
    mx = sx / n
    my = sy / n
    for (i = 1; i <= n; i++) {
      dx = x[i] - mx
      dy = y[i] - my
      sxx += dx * dx
      sxy += dx * dy
    }
    if (sxx == 0) {
      print "every flash was at the same instant" >"/dev/stderr"
      exit 1
    }
    b = sxy / sxx
    a = my - b * mx
    worst = 0
    for (i = 1; i <= n; i++) {
      r = y[i] - (a + b * x[i])
      squares += r * r
      if (r < 0) r = -r
      if (r > worst) worst = r
    }
    # worst is how far one flash sits from the line, and a screen only changes
    # 60 times a second, so that is up to half a frame whatever the clock says.
    # What the mapping itself is worth is how well the line sits: the spread of
    # those errors over the number of edges.
    spread = sqrt(squares / n) / sqrt(n)
    printf "%.9f %.9f %.1f %.1f %d\n", a, b, worst * 1000, spread * 1000, n
  }' "$pairs" >"$tmp/fit"

read -r offset drift residual spread count <"$tmp/fit"
{
  printf '# the phone'"'"'s clock in the recording, from %s flashed edges\n' "$count"
  printf '# video_seconds = offset_s + drift * (device_ns - ref_ns) / 1e9\n'
  printf 'ref_ns %s\n' "$ref"
  printf 'offset_s %s\n' "$offset"
  printf 'drift %s\n' "$drift"
  printf 'drift_ppm %s\n' "$(awk -v b="$drift" 'BEGIN { printf "%.1f", (b - 1) * 1e6 }')"
  printf 'worst_edge_ms %s\n' "$residual"
  printf 'fit_ms %s\n' "$spread"
  printf 'edges %s\n' "$count"
} >"$dir/clock.txt"

# What the mapping is worth is the fit: one flash can be a few frames off when
# the encoder was busy with something else, and that says nothing about where
# the next action will be. The worst edge is in clock.txt for when it matters.
printf 'clock: %s edges, +/- %s ms, offset %s s, drift %s ppm\n' \
  "$count" "$spread" "$offset" \
  "$(awk -v b="$drift" 'BEGIN { printf "%.1f", (b - 1) * 1e6 }')"
