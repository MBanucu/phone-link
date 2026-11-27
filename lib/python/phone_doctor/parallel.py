"""Run the independent check modules, sequentially or on a thread pool.

Every check reads shared state through `Context` and writes only files that
already belong to it, so the modules are independent. The one ordering rule is
that the report reads in `MODULES` order even when the work finished out of
order: each module keeps its index, and the sections are assembled from those
indexes after the pool is done.

`on_section` and `on_result` are called exactly once per event, as soon as that
module finishes. They are what a streaming caller needs; this module never
prints and never emits a final `done` event of its own.
"""

from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Callable, Sequence

from .checks import MODULES
from .context import Context
from .model import Result, fail
from .status import Section

SectionCallback = Callable[[str], None]
ResultCallback = Callable[[str, Result], None]


def _failed(module, exc: BaseException) -> Result:
    """One stable result for a check that raised, instead of losing its peer.

    The id is derived from the module name, never from the exception or a
    thread, so repeated runs and diffing two reports stay meaningful.
    """
    name = module.__name__.rsplit(".", 1)[-1]
    label = f"{name} check"
    return fail(f"{name}_error", label, f"check raised {type(exc).__name__}: {exc}")


def _run_check(module, ctx: Context) -> tuple[Result, ...]:
    try:
        return tuple(module.check(ctx))
    except Exception as exc:  # a broken check must not take the report down
        return (_failed(module, exc),)


def collect_parallel(
    ctx: Context,
    *,
    jobs: int,
    modules: Sequence = MODULES,
    on_section: SectionCallback | None = None,
    on_result: ResultCallback | None = None,
) -> list[Section]:
    """Collect every module, preserving canonical section order in the result.

    `jobs <= 1` runs the modules in order. More than one job hands them to a
    `ThreadPoolExecutor`, and each section and its results are announced as
    that module completes; completion order is therefore not report order.
    """
    if jobs <= 1:
        sections: list[Section] = []
        for module in modules:
            if on_section is not None:
                on_section(module.SECTION)
            results = _run_check(module, ctx)
            for result in results:
                if on_result is not None:
                    on_result(module.SECTION, result)
            sections.append(Section(module.SECTION, results))
        return sections

    ordered: list[Section | None] = [None] * len(modules)
    with ThreadPoolExecutor(max_workers=jobs) as pool:
        futures = {
            pool.submit(_run_check, module, ctx): index
            for index, module in enumerate(modules)
        }
        for future in as_completed(futures):
            index = futures[future]
            module = modules[index]
            results = future.result()
            if on_section is not None:
                on_section(module.SECTION)
            for result in results:
                if on_result is not None:
                    on_result(module.SECTION, result)
            ordered[index] = Section(module.SECTION, results)
    return [section for section in ordered if section is not None]
