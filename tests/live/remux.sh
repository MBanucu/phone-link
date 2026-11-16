#!/usr/bin/env bash
# Make a run's recording playable and seekable from its first byte.
#
#   tests/live/remux.sh result-live/<run>/screen.mp4
#
# `screenrecord` writes a plain MP4 with its index (`moov`) at the end, so the
# file cannot be played, seeked or previewed until the recorder has closed it,
# and a run that is cut short leaves a file with no index at all. The pixels are
# already H.264, so nothing has to be decoded: a remux copies the streams and
# moves the index to the front, which makes the same file play from the first
# byte in a browser, a player or a mail attachment.
#
# The index is checked afterwards, not trusted: the point of the pass is the
# first bytes, so the file is reopened and `moov` has to be in the part of it a
# player reads first. A failed remux leaves the original alone.
#
# The recording is remuxed in place, with the new file beside it and moved over
# only once it has been read back: an interrupted run then keeps whatever the
# phone wrote rather than half of something else. Peak disk is both copies for
# the length of one pass (seconds for 5–80 MB, and no decode).
#
# ffmpeg is expected on the host (nixpkgs.ffmpeg); PHONE_LIVE_FFMPEG overrides.
set -eu

usage() {
  printf 'usage: %s RECORDING\n' "${0##*/}" >&2
  exit 2
}

recording=${1:-}
[ -n "$recording" ] || usage
[ -f "$recording" ] || {
  printf 'no such recording: %s\n' "$recording" >&2
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

# The first bytes a player reads: a fast-start MP4 has its index in them. The
# window is generous — the index of a long run is a few hundred kilobytes — but
# bounded, so a file that still has the index at the end fails here instead of
# quietly being kept.
window=${PHONE_LIVE_REMUX_WINDOW:-262144}

# The copy has a .mp4 name so ffmpeg knows what to write, and is moved over
# the original only after it has been read back.
tmp=${recording%.*}.remux.tmp.mp4
[ "$tmp" != "$recording" ] || tmp=$recording.remux.tmp.mp4
rm -f "$tmp"
# screenrecord adds `mett` metadata tracks beside the video; MP4 will not take
# a stream copy of them, and they are not the pixels. The video (and an audio
# track, if a recording ever has one) is what plays and what the clock fit
# reads, so those are what is kept.
if ! "$ffmpeg" -nostdin -loglevel error -y -i "$recording" \
  -map 0:v -map 0:a? -c copy -movflags +faststart "$tmp"; then
  rm -f "$tmp"
  printf 'could not remux %s; the recording is unchanged\n' "$recording" >&2
  exit 1
fi
if ! head -c "$window" "$tmp" | grep -aq 'moov'; then
  rm -f "$tmp"
  printf 'the index is not at the front of the remuxed file; keeping %s\n' \
    "$recording" >&2
  exit 1
fi
mv -f "$tmp" "$recording"
printf 'remuxed: %s plays from its first byte\n' "$recording"
