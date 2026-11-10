"""Collect every check once, in report order.

The text report (`phone-doctor`), its `--json` form and the GUI all read this,
so a check that exists in one is visible in the others.
"""

from __future__ import annotations

from dataclasses import dataclass

from .checks import MODULES
from .context import Context
from .model import Result, Status


@dataclass(frozen=True)
class Section:
    name: str
    results: tuple[Result, ...]


def collect(ctx: Context | None = None) -> list[Section]:
    context = ctx or Context()
    return [Section(module.SECTION, tuple(module.check(context))) for module in MODULES]


def summary(sections: list[Section]) -> dict[str, int]:
    counts = {status.value: 0 for status in Status}
    for section in sections:
        for result in section.results:
            counts[result.status.value] += 1
    return counts


def ready(sections: list[Section]) -> bool:
    return summary(sections)["fail"] == 0
