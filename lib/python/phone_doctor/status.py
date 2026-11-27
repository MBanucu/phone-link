"""Collect every check once, in report order.

The text report (`phone-doctor`), its `--json` form and the GUI all read this,
so a check that exists in one is visible in the others.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Callable

from .checks import MODULES
from .context import Context
from .model import Result, Status


@dataclass(frozen=True)
class Section:
    name: str
    results: tuple[Result, ...]


def section_names() -> tuple[str, ...]:
    """Every section in report order, without running a check."""
    return tuple(module.SECTION for module in MODULES)


def collect(
    ctx: Context | None = None,
    *,
    on_section: Callable[[str], None] | None = None,
    on_result: Callable[[str, Result], None] | None = None,
) -> list[Section]:
    """Run every check once, optionally reporting each section and result.

    The callbacks fire in MODULES order: a section before its checks run, then
    each result as soon as that section's check returns it. They share this
    single loop, so the text report, `--json`, `--json-stream` and the GUI can
    never disagree about what was checked or in what order.
    """
    context = ctx or Context()
    sections: list[Section] = []
    for module in MODULES:
        name = module.SECTION
        if on_section is not None:
            on_section(name)
        results = tuple(module.check(context))
        sections.append(Section(name, results))
        if on_result is not None:
            for result in results:
                on_result(name, result)
    return sections


def summary(sections: list[Section]) -> dict[str, int]:
    counts = {status.value: 0 for status in Status}
    for section in sections:
        for result in section.results:
            counts[result.status.value] += 1
    return counts


def ready(sections: list[Section]) -> bool:
    return summary(sections)["fail"] == 0
