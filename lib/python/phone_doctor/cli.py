"""CLI: same flags, ids, ordering and exit codes as the bash doctor."""

from __future__ import annotations

import argparse
import json
import sys

from .checks import MODULES
from .context import Context
from .parallel import collect_parallel
from .report import Report
from .status import summary


def _jobs(value: str) -> int:
    if value == "auto":
        return min(8, len(MODULES))
    try:
        jobs = int(value)
    except ValueError:
        raise argparse.ArgumentTypeError(
            f"invalid job count: {value!r} (use a positive integer or 'auto')"
        ) from None
    if jobs < 1:
        raise argparse.ArgumentTypeError("job count must be at least 1")
    return jobs


def _payload(sections) -> dict:
    counts = summary(sections)
    return {
        "ready": counts["fail"] == 0,
        "counts": counts,
        "sections": [
            {
                "name": section.name,
                "results": [
                    {
                        "status": result.status.value,
                        "id": result.cid,
                        "label": result.label,
                        "detail": result.detail,
                    }
                    for result in section.results
                ],
            }
            for section in sections
        ],
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="phone-doctor",
        description=(
            "Check the runtime conditions of the whole phone-link setup. "
            "Read-only."
        ),
        epilog=(
            "--analyze prints one 'fail|warn ID detail' line per problem for "
            "scripts such as phone-doctor-fix; --json prints the same results "
            "as a document for the GUI. Exits 0 when every required condition "
            "is met and 1 otherwise."
        ),
    )
    output = parser.add_mutually_exclusive_group()
    output.add_argument(
        "--analyze",
        action="store_true",
        help="only print problems as 'status id detail' lines",
    )
    output.add_argument(
        "--json",
        action="store_true",
        help="print every result as JSON, for the GUI",
    )
    parser.add_argument(
        "--jobs",
        type=_jobs,
        default=1,
        metavar="N|auto",
        help=(
            "run independent checks on N threads, or 'auto' for "
            "min(8, sections); the report stays in section order (default: 1)"
        ),
    )
    args = parser.parse_args(argv)

    sections = collect_parallel(Context(), jobs=args.jobs)
    if args.json:
        payload = _payload(sections)
        print(json.dumps(payload, indent=2))
        return 0 if payload["ready"] else 1

    report = Report(args.analyze)
    for section in sections:
        report.section(section.name)
        for result in section.results:
            report.add(result)
    return report.finish()


if __name__ == "__main__":
    sys.exit(main())
