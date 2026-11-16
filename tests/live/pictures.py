#!/usr/bin/env python3
"""The frames that explain a failed check, out of the run's own recording.

A failed run already leaves the phone's screen as `screen.mp4` and the phone's
clock tied into it (`clock.txt`), and every action and every capture stamped
with that clock. What it did not do was use them: a person looking at a failure
had to search the video by hand for the moment a check was decided. This takes
the failure notes the harness leaves (`failures.csv`: the check, the step, its
start, the check's instant and the step's end) and pulls the frames worth
looking at into the run's folder, named after what they show:

    frame-<check>-step-start.png
    frame-<check>-action-3-before.png
    frame-<check>-capture-7-after.png
    frame-<check>-check.png
    frame-<check>-step-end.png

A frame "before" an action is a fraction of a second earlier, and one "after" a
capture a fraction later, because the instant an action is stamped is when the
phone took it and a capture is stamped when the screen had already changed.
Both are a setting: `--before`, `--after`.

    tests/live/pictures.py result-live/<run>            # writes the frames
    tests/live/pictures.py --plan result-live/<run>     # only what it would take

`--plan` prints `name,seconds` and needs no ffmpeg, which is what the hermetic
test covers. With a recording, ffmpeg is expected on the host
(PHONE_LIVE_FFMPEG overrides).
"""

from __future__ import annotations

import argparse
import csv
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


def read_clock(run: Path) -> tuple[float, float, float]:
    """clock.txt: video_seconds = offset + drift * (device_ns - ref) / 1e9."""
    values: dict[str, float] = {}
    try:
        for line in (run / "clock.txt").read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            key, _, value = line.partition(" ")
            values[key] = float(value)
    except (OSError, ValueError) as error:
        raise SystemExit(f"cannot read the clock mapping: {error}")
    try:
        return values["ref_ns"], values["offset_s"], values["drift"]
    except KeyError:
        raise SystemExit("clock.txt has no ref_ns/offset_s/drift")


def video_seconds(clock: tuple[float, float, float], device_ns: int) -> float:
    ref, offset, drift = clock
    return offset + drift * (device_ns - ref) / 1e9


def read_failures(run: Path) -> list[dict[str, str]]:
    path = run / "failures.csv"
    if not path.exists():
        return []
    with path.open(newline="", encoding="utf-8") as handle:
        return [row for row in csv.DictReader(handle) if row.get("fail_ns")]


def read_events(run: Path, name: str) -> list[int]:
    """The instant of every row in an actions file, in file order."""
    path = run / name
    if not path.exists():
        return []
    stamps = []
    with path.open(newline="", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            field = line.split(",", 1)[0].strip()
            if field.isdigit():
                stamps.append(int(field))
    return stamps


def read_captures(run: Path) -> list[int]:
    """ui-index.csv: n, device_ns, wall_ms, trigger — the capture's instant."""
    path = run / "ui-index.csv"
    if not path.exists():
        return []
    stamps = []
    with path.open(newline="", encoding="utf-8", errors="replace") as handle:
        for row in csv.DictReader(handle):
            if row.get("device_ns", "").isdigit():
                stamps.append(int(row["device_ns"]))
    return stamps


def plan(run: Path, before: float, after: float, duration: float | None):
    """Every frame, flattened, in the order the run would take them."""
    for check, frames in by_failure(run, before, after, duration):
        for name, seconds in frames:
            yield name, seconds


def by_failure(run: Path, before: float, after: float, duration: float | None):
    """Per failed check: the frames that explain it, named after what they show."""
    clock = read_clock(run)
    events = [("action", stamp) for stamp in read_events(run, "actions.csv")]
    # Typing goes through `input` and is in a file of its own; it is an action
    # the harness took, so it gets a frame too.
    events += [("input", stamp) for stamp in read_events(run, "input.csv")]
    events.sort(key=lambda item: item[1])
    captures = read_captures(run)

    for failure in read_failures(run):
        check = failure["check"]
        start = int(failure.get("start_ns") or 0)
        decided = int(failure["fail_ns"])
        end = int(failure.get("end_ns") or decided)
        if start <= 0:
            start = decided
        offsets: list[tuple[str, float]] = [("step-start", video_seconds(clock, start))]
        counters: dict[str, int] = {}
        for kind, stamp in events:
            if stamp < start or stamp > end:
                continue
            counters[kind] = counters.get(kind, 0) + 1
            offsets.append(
                (f"{kind}-{counters[kind]}-before",
                 video_seconds(clock, stamp) - before)
            )
        capture = 0
        for stamp in captures:
            if stamp < start or stamp > end:
                continue
            capture += 1
            offsets.append(
                (f"capture-{capture}-after", video_seconds(clock, stamp) + after)
            )
        offsets.append(("check", video_seconds(clock, decided)))
        offsets.append(("step-end", video_seconds(clock, end)))
        frames = []
        for name, seconds in offsets:
            if seconds < 0:
                seconds = 0.0
            if duration is not None and seconds > duration:
                seconds = max(0.0, duration)
            frames.append((f"frame-{check}-{name}.png", seconds))
        yield check, frames


def extract(
    ffmpeg: str, recording: Path, run: Path, frames: list[tuple[str, float]]
) -> list[tuple[str, float]]:
    """Write one failed check's frames, from one pass over its part of the video.

    A seek per frame decodes from the previous keyframe every time, and this
    phone's recordings are 1440x3200: 54 frames of one 16-second step took
    nearly two minutes that way. One pass selects the wanted instants together
    and writes them in order; the names go on afterwards. A still screen can
    leave a moment with no frame within a few milliseconds of it, and then the
    count does not match — those frames are pulled one at a time, which always
    finds the nearest one.
    """
    ordered = sorted(frames, key=lambda item: item[1])
    start = max(0.0, ordered[0][1] - 1.0)
    span = max(0.5, ordered[-1][1] - start + 1.0)
    # A window around each wanted instant, wide enough that a frame is in it
    # unless the screen was still, and narrow enough that the frames it does
    # find are the ones around that moment.
    eps = 0.10
    watch = "+".join(
        f"between(t,{seconds - start - eps:.3f},{seconds - start + eps:.3f})"
        for _, seconds in ordered
    )

    work = Path(tempfile.mkdtemp(prefix=".frames-", dir=run))
    missing = list(ordered)
    try:
        result = subprocess.run(
            [
                ffmpeg,
                "-nostdin",
                "-hide_banner",
                "-loglevel",
                "info",
                "-y",
                "-ss",
                f"{start:.3f}",
                "-i",
                str(recording),
                "-t",
                f"{span:.3f}",
                "-vf",
                f"select='{watch}',showinfo",
                "-fps_mode",
                "passthrough",
                "-q:v",
                "2",
                str(work / "%05d.png"),
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        times = [
            float(found)
            for found in re.findall(r"pts_time:([0-9.]+)", result.stderr or "")
        ]
        made = sorted(work.glob("*.png"))
        if result.returncode == 0 and times and len(times) == len(made):
            # Each wanted moment takes the frame nearest its own instant, not
            # the first one the window happened to hold. A still screen leaves
            # a moment with no frame of its own, and that one is left for the
            # slow path rather than dragged from a different part of the step.
            placed = 0
            missing = []
            for name, seconds in ordered:
                relative = seconds - start
                best = min(range(len(times)), key=lambda i: abs(times[i] - relative))
                if abs(times[best] - relative) > 0.2:
                    missing.append((name, seconds))
                    continue
                shutil.copyfile(made[best], run / name)
                placed += 1
            if not placed:
                missing = list(ordered)
    finally:
        shutil.rmtree(work, ignore_errors=True)

    # The moments the pass could not place: a frame at a time, which is slower
    # but takes whatever the decoder lands on.
    for name, seconds in missing:
        frame = run / name
        result = subprocess.run(
            [
                ffmpeg,
                "-nostdin",
                "-loglevel",
                "error",
                "-y",
                "-ss",
                f"{seconds:.3f}",
                "-i",
                str(recording),
                "-frames:v",
                "1",
                "-q:v",
                "2",
                str(frame),
            ],
            check=False,
        )
        if result.returncode != 0 or not frame.exists():
            raise RuntimeError(f"no frame at {seconds:.3f}s ({name})")
    return ordered


def find_tool(name: str, override: str) -> str | None:
    if override:
        return override
    found = shutil.which(name)
    if found:
        return found
    system = Path("/run/current-system/sw/bin") / name
    if system.exists():
        return str(system)
    return None


def probe_duration(ffprobe: str, recording: Path) -> float | None:
    try:
        out = subprocess.run(
            [
                ffprobe,
                "-v",
                "error",
                "-show_entries",
                "format=duration",
                "-of",
                "csv=p=0",
                str(recording),
            ],
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError:
        return None
    try:
        return float(out.stdout.strip().splitlines()[0])
    except (ValueError, IndexError):
        return None


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description="pull the frames that explain a failed check out of a run"
    )
    parser.add_argument("run", type=Path, help="result-live/<run>")
    parser.add_argument(
        "--plan",
        action="store_true",
        help="print name,seconds instead of writing frames",
    )
    parser.add_argument(
        "--before",
        type=float,
        default=float(os.environ.get("PHONE_LIVE_FRAME_BEFORE", "0.2")),
        help="seconds before an action its frame is taken",
    )
    parser.add_argument(
        "--after",
        type=float,
        default=float(os.environ.get("PHONE_LIVE_FRAME_AFTER", "0.2")),
        help="seconds after a capture its frame is taken",
    )
    parser.add_argument(
        "--duration",
        type=float,
        default=None,
        help="the recording's length, so a frame is not asked for past its end",
    )
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args(argv)

    run = args.run
    if not run.is_dir():
        print(f"no run folder: {run}", file=sys.stderr)
        return 2
    if not read_failures(run):
        if not args.quiet:
            print("no failed check: there is nothing to pull")
        return 0

    recording = run / "screen.mp4"
    duration = args.duration
    if not args.plan and recording.exists() and duration is None:
        ffprobe = find_tool("ffprobe", os.environ.get("PHONE_LIVE_FFPROBE", ""))
        if ffprobe:
            duration = probe_duration(ffprobe, recording)

    frames = list(plan(run, args.before, args.after, duration))
    if args.plan:
        for name, seconds in frames:
            print(f"{name},{seconds:.3f}")
        return 0

    if not recording.exists():
        print(f"no recording at {recording}", file=sys.stderr)
        return 1
    ffmpeg = find_tool("ffmpeg", os.environ.get("PHONE_LIVE_FFMPEG", ""))
    if not ffmpeg:
        print("no ffmpeg: install it or set PHONE_LIVE_FFMPEG", file=sys.stderr)
        return 1
    for check, frames in by_failure(run, args.before, args.after, duration):
        try:
            written = extract(ffmpeg, recording, run, frames)
        except RuntimeError as error:
            print(str(error), file=sys.stderr)
            return 1
        if not args.quiet:
            for frame, _ in sorted(written, key=lambda item: item[1]):
                print(run / frame)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
