#!/usr/bin/env bash
# Build the flake's script check and keep how long each suite took.
#
#   bash tests/check-timings.sh
#
# The check times itself and writes `timings.csv` into its output, one row per
# suite plus the parts a suite knows about (proxy-app.test.sh splits its `javac`
# from its `cases`). A store path is immutable, so nothing there can be compared
# with the last build; this copies the rows into `result-checks/timings.csv`,
# append-only and keyed by run like `result-live/timings.csv`, and prints each
# suite beside the last time it was measured. The point is not a fast build
# once, it is knowing which suite moved when the check gets slower.
#
# SYSTEM=, CHECK_OUT= and CHECK_TIMINGS= override what it builds and where the
# numbers go; `nix build .#checks.x86_64-linux.script` on its own still times
# itself, it just keeps no history.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SYSTEM=${SYSTEM:-x86_64-linux}
OUT=${CHECK_OUT:-$ROOT/result-script}
HISTORY=${CHECK_TIMINGS:-$ROOT/result-checks/timings.csv}
TARGET="checks.$SYSTEM.script"

printf 'building %s\n' "$TARGET"
if ! nix build "$ROOT#$TARGET" -o "$OUT" --no-write-lock-file; then
  printf '\nthe check did not build, so nothing was timed\n' >&2
  exit 1
fi

python3 - "$OUT/timings.csv" "$HISTORY" <<'PY'
import csv, os, sys, time

current, history = sys.argv[1], sys.argv[2]
rows = list(csv.DictReader(open(current)))
run = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())

# What the last build said, before this run is appended: the last row per
# (suite, part) wins because the file is append-only and so in time order. The
# part is in the key because one suite contributes several rows — a total, and
# the javac and cases it knows about — and those are not comparable with each
# other.
last = {}
if os.path.exists(history):
    for row in csv.DictReader(open(history)):
        last[(row["suite"], row["part"])] = (row["run"], float(row["ms"]) / 1000)

labels = [
    r["suite"] if r["part"] == "total" else f"{r['suite']} ({r['part']})"
    for r in rows
]
width = max([len(label) for label in labels] + [5])
print(f"\n{'suite':<{width}}  {'now':>9}  {'last':>9}  change")
for row, label in zip(rows, labels):
    ms = float(row["ms"]) / 1000
    was = last.get((row["suite"], row["part"]))
    change = f"{ms - was[1]:+.2f} s" if was else "first run"
    before = f"{was[1]:.2f} s" if was else "-"
    print(f"{label:<{width}}  {ms:9.2f}  {before:>9}  {change}")

# Only the `total` rows are the check's own time; a part row (a suite's javac,
# say) is inside its suite and counting it again would make the sum wrong.
totals = [float(r["ms"]) / 1000 for r in rows if r["part"] == "total"]
parts = len(rows) - len(totals)
print(
    f"\n{len(totals)} suites, {sum(totals):.2f} s of suite time this build"
    + (f" ({parts} part rows inside them)" if parts else "")
)

os.makedirs(os.path.dirname(history) or ".", exist_ok=True)
fresh = not os.path.exists(history)
with open(history, "a", newline="") as f:
    writer = csv.writer(f)
    if fresh:
        writer.writerow(["run", "suite", "part", "ms"])
    for row in rows:
        writer.writerow([run, row["suite"], row["part"], row["ms"]])
print(f"appended run {run} to {history}")
PY
