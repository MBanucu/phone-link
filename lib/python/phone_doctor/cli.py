"""CLI: same flags, ids, ordering and exit codes as the bash doctor."""

from __future__ import annotations

import argparse
import json
import sys

from .report import Report
from .status import collect, summary


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
    args = parser.parse_args(argv)

    sections = collect()
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
