"""Rendering and exit status, identical to the bash doctor's contract."""

from __future__ import annotations

import sys

from .model import Result, Status


class Report:
    def __init__(self, analyze: bool) -> None:
        self.analyze = analyze
        self.ok = 0
        self.failed = 0
        self.warned = 0

    def section(self, name: str) -> None:
        if not self.analyze:
            print(f"\n{name}")

    def add(self, result: Result) -> None:
        if result.status is Status.OK:
            self.ok += 1
            if not self.analyze:
                print(f"{'ok':<5} {result.label:<20} {result.detail}")
        elif result.status is Status.WARN:
            self.warned += 1
            if self.analyze:
                print(f"warn {result.cid} {result.detail}")
            else:
                print(f"{'warn':<5} {result.label:<20} {result.detail}")
        elif result.status is Status.FAIL:
            self.failed += 1
            if self.analyze:
                print(f"fail {result.cid} {result.detail}")
            else:
                print(f"{'FAIL':<5} {result.label:<20} {result.detail}")
        elif not self.analyze:
            print(f"{'skip':<5} {result.label:<20} {result.detail}")

    def finish(self) -> int:
        if self.analyze:
            return 1 if self.failed else 0
        print(f"\n{self.ok} ok, {self.failed} failed, {self.warned} warnings")
        if self.failed:
            print(
                "verdict: setup is not ready "
                f"({self.failed} required condition(s) failed)",
                file=sys.stderr,
            )
            return 1
        if self.warned:
            print(
                "verdict: required conditions are met; "
                f"{self.warned} optional condition(s) open"
            )
        else:
            print("verdict: the whole setup is ready")
        return 0
