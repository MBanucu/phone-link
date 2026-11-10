"""CLI: same flags, ids, ordering and exit codes as the bash doctor."""

from __future__ import annotations

import argparse
import sys

from .checks import MODULES
from .context import Context
from .report import Report


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="phone-doctor",
        description=(
            "Check the runtime conditions of the whole phone-link setup. "
            "Read-only."
        ),
        epilog=(
            "--analyze prints one 'fail|warn ID detail' line per problem for "
            "scripts such as phone-doctor-fix. Exits 0 when every required "
            "condition is met and 1 otherwise."
        ),
    )
    parser.add_argument(
        "--analyze",
        action="store_true",
        help="only print problems as 'status id detail' lines",
    )
    args = parser.parse_args(argv)

    ctx = Context()
    report = Report(args.analyze)
    for module in MODULES:
        report.section(module.SECTION)
        for result in module.check(ctx):
            report.add(result)
    return report.finish()


if __name__ == "__main__":
    sys.exit(main())
