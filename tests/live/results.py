#!/usr/bin/env python3
"""A queryable copy of the runs this checkout has made.

The CSVs stay the record: every run appends its steps to
`result-live/timings.csv` (or `timings-partial.csv`), and every check to
`checks.csv` in the run's own folder. That is what a run writes as it goes, and
what a run needs no database to start. This reads them once and fills a small
SQLite file beside them, so the questions a CSV makes awkward — a step's median
per kind of run, whether a check failed before, which steps got slower after a
change, what a full run costs on this device — are one `sqlite3` away.

    tests/live/results.py                     # result-live/results.sqlite3
    tests/live/results.py --results DIR --db FILE

One-way and repeatable: the CSVs are never written, a run already in the
database is replaced from its files, and a schema change costs a re-import
instead of the history. Nothing here is needed by a run or by a check.

The settings a run read (which build, which phone, capture, the steps asked
for) live beside its checks as `run.csv`, `key,value` rows; a run from before
that file existed is still imported, with what its timing rows say.
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import sqlite3
import sys
from datetime import datetime, timezone
from pathlib import Path

SCHEMA = """
CREATE TABLE IF NOT EXISTS runs (
    id TEXT PRIMARY KEY,
    kind TEXT NOT NULL,              -- full | filtered | unknown
    steps_asked TEXT,                -- the names PHONE_LIVE_ONLY asked for
    started TEXT,                    -- ISO 8601, UTC
    seconds REAL,
    passed INTEGER,
    failed INTEGER,
    status TEXT,                     -- ok | failed | partial | unknown
    device TEXT,
    app_build TEXT,
    capture INTEGER,                 -- 1 recorded, 0 not, NULL unrecorded
    settings TEXT                    -- JSON of every other setting the run read
);
CREATE TABLE IF NOT EXISTS steps (
    run TEXT NOT NULL REFERENCES runs(id),
    name TEXT NOT NULL,
    position INTEGER NOT NULL,       -- the order the run took them in
    seconds REAL,
    passed INTEGER,
    failed INTEGER,
    status TEXT,                     -- ok | failed
    PRIMARY KEY (run, name)
);
CREATE TABLE IF NOT EXISTS checks (
    run TEXT NOT NULL REFERENCES runs(id),
    step TEXT,
    verdict TEXT,                    -- pass | fail
    claim TEXT,
    file TEXT,
    line INTEGER,
    function TEXT,
    decided_ms INTEGER
);
CREATE INDEX IF NOT EXISTS checks_by_claim ON checks (claim);
CREATE INDEX IF NOT EXISTS steps_by_name ON steps (name);
"""

# The settings the schema has columns for; everything else a run.csv carries is
# kept as JSON, so a setting added to the harness needs no migration here.
COLUMNS = {
    "kind",
    "steps_asked",
    "started",
    "seconds",
    "passed",
    "failed",
    "status",
    "device",
    "app_build",
    "capture",
}

# Timing rows that are a run's total rather than a step.
TOTALS = {"TOTAL", "PARTIAL"}


def read_rows(path: Path) -> list[dict[str, str]]:
    """timings.csv, tolerant of a file that is still being appended to."""
    if not path.exists():
        return []
    with path.open(newline="", encoding="utf-8", errors="replace") as handle:
        reader = csv.DictReader(handle)
        if not reader.fieldnames:
            return []
        rows = []
        for row in reader:
            if row.get("run") and row.get("step"):
                rows.append(row)
        return rows


def read_settings(path: Path) -> dict[str, str]:
    """run.csv: key,value rows; last one wins, like a repeated flag."""
    if not path.exists():
        return {}
    values: dict[str, str] = {}
    with path.open(newline="", encoding="utf-8", errors="replace") as handle:
        for row in csv.reader(handle):
            if len(row) == 2 and row[0] and row[0] != "key":
                values[row[0]] = row[1]
    return values


def read_checks(path: Path) -> list[dict[str, str]]:
    if not path.exists():
        return []
    with path.open(newline="", encoding="utf-8", errors="replace") as handle:
        reader = csv.DictReader(handle)
        if not reader.fieldnames:
            return []
        return [row for row in reader if row.get("verdict")]


def started_from_id(run: str) -> str | None:
    """The run id is its UTC start, to the second: 20261116T021422Z."""
    try:
        stamp = datetime.strptime(run, "%Y%m%dT%H%M%SZ")
    except ValueError:
        return None
    return stamp.replace(tzinfo=timezone.utc).isoformat()


def number(text: str | None, cast=float):
    if text is None or text == "":
        return None
    try:
        return cast(text)
    except ValueError:
        return None


def collect(results: Path) -> tuple[dict[str, dict], list[str]]:
    """Every run the CSVs know, merged from the timing files and its folder."""
    timings = {
        "full": read_rows(results / "timings.csv"),
        "filtered": read_rows(results / "timings-partial.csv"),
    }
    runs: dict[str, dict] = {}
    problems: list[str] = []

    # A run is its TOTAL/PARTIAL row: that is the line a run writes when it
    # ends, and the file it is in says what kind of run it was.
    for kind, rows in timings.items():
        for row in rows:
            if row["step"] not in TOTALS:
                continue
            run = runs.setdefault(
                row["run"],
                {
                    "id": row["run"],
                    "kind": kind,
                    "steps": [],
                    "checks": [],
                    "settings": {},
                },
            )
            run["seconds"] = number(row.get("seconds"))
            run["passed"] = number(row.get("passed"), int)
            run["failed"] = number(row.get("failed"), int)
            # A PARTIAL row is a filtered run, whichever file it sits in: the
            # full history still holds the filtered runs made before they had
            # a history of their own.
            if kind == "filtered" or row["step"] == "PARTIAL":
                run["kind"] = "filtered"
                run["status"] = "partial"
            else:
                run["status"] = row.get("status") or "unknown"

    # Steps, in the order each run took them; the file is append-only, so that
    # is the order of its rows for that run.
    for rows in timings.values():
        seen: dict[str, int] = {}
        for row in rows:
            if row["step"] in TOTALS:
                continue
            run = runs.get(row["run"])
            if run is None:
                # An interrupted run that never wrote a total: still a run.
                run = runs.setdefault(
                    row["run"],
                    {
                        "id": row["run"],
                        "kind": "unknown",
                        "steps": [],
                        "checks": [],
                        "settings": {},
                    },
                )
                run["status"] = "unknown"
            if row["step"] in seen:
                continue
            seen[row["step"]] = len(seen) + 1
            run["steps"].append(
                {
                    "name": row["step"],
                    "position": len(seen),
                    "seconds": number(row.get("seconds")),
                    "passed": number(row.get("passed"), int),
                    "failed": number(row.get("failed"), int),
                    "status": row.get("status") or "unknown",
                }
            )

    # And every run's own folder: its settings and its checks.
    for folder in sorted(results.iterdir()) if results.is_dir() else []:
        if not folder.is_dir() or not folder.name[:8].isdigit():
            continue
        settings = read_settings(folder / "run.csv")
        checks = read_checks(folder / "checks.csv")
        run = runs.get(folder.name)
        if run is None and not (settings or checks):
            continue
        if run is None:
            run = runs.setdefault(
                folder.name,
                {
                    "id": folder.name,
                    "kind": "unknown",
                    "steps": [],
                    "checks": [],
                    "settings": {},
                },
            )
            run["status"] = "unknown"
        run["settings"] = settings
        run["checks"] = checks
        # The folder is the run's own copy of the facts, so a setting there is
        # the answer even when the timing file knows nothing.
        if settings.get("kind") in {"full", "filtered"}:
            run["kind"] = settings["kind"]
        for field, cast in (
            ("seconds", float),
            ("passed", int),
            ("failed", int),
        ):
            if settings.get(field):
                run[field] = number(settings[field], cast)
        if not run["steps"] and checks:
            # A run whose timings were lost still says which steps it took.
            order: list[str] = []
            for check in checks:
                if check.get("step") and check["step"] not in order:
                    order.append(check["step"])
            for position, name in enumerate(order, start=1):
                run["steps"].append(
                    {
                        "name": name,
                        "position": position,
                        "seconds": None,
                        "passed": None,
                        "failed": None,
                        "status": "unknown",
                    }
                )
        if not settings:
            problems.append(f"{folder.name}: no run.csv (settings unknown)")

    for run in runs.values():
        if "started" not in run:
            run["started"] = started_from_id(run["id"]) or ""
        # A filtered run is partial by definition — it never wrote a TOTAL row —
        # so its status does not have to come from a setting.
        if run["kind"] == "filtered":
            run["status"] = "partial"
        elif not run.get("status"):
            run["status"] = "unknown"
    return runs, problems


def import_runs(results: Path, database: Path) -> tuple[int, int, int]:
    runs, problems = collect(results)
    database.parent.mkdir(parents=True, exist_ok=True)
    connection = sqlite3.connect(database)
    try:
        connection.executescript(SCHEMA)
        with connection:
            for run in runs.values():
                settings = dict(run.get("settings") or {})
                extra = {
                    key: value
                    for key, value in settings.items()
                    if key not in COLUMNS and key not in {"run"}
                }
                connection.execute(
                    """
                    INSERT INTO runs
                        (id, kind, steps_asked, started, seconds, passed,
                         failed, status, device, app_build, capture, settings)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        kind = excluded.kind,
                        steps_asked = excluded.steps_asked,
                        started = excluded.started,
                        seconds = excluded.seconds,
                        passed = excluded.passed,
                        failed = excluded.failed,
                        status = excluded.status,
                        device = excluded.device,
                        app_build = excluded.app_build,
                        capture = excluded.capture,
                        settings = excluded.settings
                    """,
                    (
                        run["id"],
                        run["kind"],
                        settings.get("steps_asked") or None,
                        run.get("started") or None,
                        run.get("seconds"),
                        run.get("passed"),
                        run.get("failed"),
                        run.get("status") or "unknown",
                        settings.get("device") or None,
                        settings.get("app_build") or None,
                        number(settings.get("capture"), int)
                        if settings.get("capture") not in (None, "")
                        else None,
                        json.dumps(extra, sort_keys=True) if extra else None,
                    ),
                )
                connection.execute("DELETE FROM steps WHERE run = ?", (run["id"],))
                connection.executemany(
                    """
                    INSERT INTO steps
                        (run, name, position, seconds, passed, failed, status)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    [
                        (
                            run["id"],
                            step["name"],
                            step["position"],
                            step["seconds"],
                            step["passed"],
                            step["failed"],
                            step["status"],
                        )
                        for step in run["steps"]
                    ],
                )
                connection.execute("DELETE FROM checks WHERE run = ?", (run["id"],))
                connection.executemany(
                    """
                    INSERT INTO checks
                        (run, step, verdict, claim, file, line, function,
                         decided_ms)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    [
                        (
                            run["id"],
                            check.get("step") or None,
                            check.get("verdict") or None,
                            check.get("claim") or None,
                            check.get("file") or None,
                            number(check.get("line"), int),
                            check.get("function") or None,
                            number(check.get("decided_ms"), int),
                        )
                        for check in run["checks"]
                    ],
                )
    finally:
        connection.close()
    if problems and os.environ.get("PHONE_RESULTS_QUIET") != "1":
        # One line, with the first few named: a history mostly older than
        # run.csv is normal, and a page of identical notes is not a warning.
        names = ", ".join(problem.split(":")[0] for problem in problems[:3])
        more = "" if len(problems) <= 3 else f" and {len(problems) - 3} more"
        print(
            f"note: {len(problems)} run folders left no run.csv "
            f"(settings unknown): {names}{more}",
            file=sys.stderr,
        )
    return (
        len(runs),
        sum(len(run["steps"]) for run in runs.values()),
        sum(len(run["checks"]) for run in runs.values()),
    )


def main(argv: list[str]) -> int:
    root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(
        description="fill a SQLite copy of the live runs from their CSVs"
    )
    parser.add_argument(
        "--results",
        type=Path,
        default=Path(os.environ.get("PHONE_LIVE_RESULTS") or root / "result-live"),
        help="the folder holding timings.csv and the run folders",
    )
    parser.add_argument(
        "--db",
        type=Path,
        default=None,
        help="the database to write (default: results/results.sqlite3)",
    )
    args = parser.parse_args(argv)
    results = args.results
    database = args.db or results / "results.sqlite3"
    if not results.is_dir():
        print(f"no results folder: {results}", file=sys.stderr)
        return 2
    runs, steps, checks = import_runs(results, database)
    if os.environ.get("PHONE_RESULTS_QUIET") != "1":
        print(f"{runs} runs, {steps} steps, {checks} checks -> {database}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
