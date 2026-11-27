"""The status page's stream state, with no GTK in it.

`phone-doctor --json-stream` emits one NDJSON event per line. This module turns
those lines into rows and counts, so the widget code only has to draw the
change; the parser and the pending -> result state machine are unit-testable
without a display.

The events are:

    {"event": "section", "name": "[flake]"}
    {"event": "result", "section": "[flake]", "result": {...}}
    {"event": "done", "ready": true, "counts": {...}}

A line that is not one of those is ignored, because the runner merges stderr
into stdout and a warning must not break the report.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Iterable

from phone_doctor.model import Status

PENDING = "pending"
STATUSES = {status.value for status in Status}


def parse_line(line: str) -> dict | None:
    """One event from one output line, or None for anything that is not one."""
    text = line.strip()
    if not text or not text.startswith("{"):
        return None
    try:
        event = json.loads(text)
    except ValueError:
        return None
    if not isinstance(event, dict):
        return None
    if event.get("event") not in ("section", "result", "done"):
        return None
    return event


@dataclass
class Row:
    section: str
    cid: str
    label: str
    status: str
    detail: str = ""
    # What the row showed before this refresh, so an unfinished run can put a
    # check back instead of leaving it spinning forever.
    previous: tuple[str, str] | None = None

    @property
    def pending(self) -> bool:
        return self.status == PENDING


@dataclass
class Change:
    kind: str
    section: str = ""
    row: Row | None = None
    new_section: bool = False
    new_row: bool = False
    accepted: bool = True


class StatusStream:
    """The rows of one page, seeded from the last report and then streamed.

    `sections` is used for the first-run skeleton. `report` is the previous
    `--json` document: its rows paint the first frame and only those ids are
    updated, so a stale or reordered event cannot invent a row.
    """

    def __init__(
        self,
        sections: Iterable[str] = (),
        report: dict | None = None,
    ) -> None:
        self.sections: list[str] = []
        self.rows: dict[str, dict[str, Row]] = {}
        self.done = False
        self.ready: bool | None = None
        self.error = ""
        self._seeded = report is not None
        if report is not None:
            self._seed(report)
        else:
            for name in sections:
                self._ensure(name)

    # -- seeding -------------------------------------------------------
    def _seed(self, report: dict) -> None:
        sections = report.get("sections")
        if isinstance(sections, list):
            for section in sections:
                if not isinstance(section, dict):
                    continue
                name = str(section.get("name") or "")
                if not name:
                    continue
                self._ensure(name)
                results = section.get("results")
                if not isinstance(results, list):
                    continue
                for result in results:
                    if not isinstance(result, dict):
                        continue
                    cid = str(result.get("id") or "")
                    if not cid:
                        continue
                    self.rows[name][cid] = Row(
                        name,
                        cid,
                        str(result.get("label") or cid),
                        str(result.get("status") or "skip"),
                        str(result.get("detail") or ""),
                    )
        self.ready = bool(report.get("ready"))

    def _ensure(self, name: str) -> bool:
        if name in self.rows:
            return False
        self.sections.append(name)
        self.rows[name] = {}
        return True

    # -- refresh -------------------------------------------------------
    def begin(self) -> None:
        """Keep every row's identity and value, but mark it pending."""
        self.done = False
        self.error = ""
        for rows in self.rows.values():
            for row in rows.values():
                if not row.pending:
                    row.previous = (row.status, row.detail)
                row.status = PENDING
                row.detail = ""

    def fail(self, message: str) -> None:
        """A run that produced no done event: put the last report back."""
        self.error = message
        self.done = False
        for rows in self.rows.values():
            for row in rows.values():
                if row.previous is not None:
                    row.status, row.detail = row.previous
                    row.previous = None

    def _restore_pending(self) -> None:
        for rows in self.rows.values():
            for row in rows.values():
                if row.pending and row.previous is not None:
                    row.status, row.detail = row.previous
        self._clear_previous()

    def _clear_previous(self) -> None:
        for rows in self.rows.values():
            for row in rows.values():
                row.previous = None

    # -- events --------------------------------------------------------
    def apply(self, event: dict) -> Change:
        kind = event.get("event")
        if kind == "section":
            name = str(event.get("name") or "")
            if not name:
                return Change("section", accepted=False)
            return Change(
                "section", section=name, new_section=self._ensure(name)
            )

        if kind == "result":
            return self._apply_result(event)

        if kind == "done":
            self.done = True
            self.ready = bool(event.get("ready"))
            self._restore_pending()
            return Change("done")

        return Change(str(kind or ""), accepted=False)

    def _apply_result(self, event: dict) -> Change:
        name = str(event.get("section") or "")
        result = event.get("result")
        if not name or not isinstance(result, dict):
            return Change("result", accepted=False)
        cid = str(result.get("id") or "")
        status = str(result.get("status") or "")
        if not cid or status not in STATUSES:
            return Change("result", accepted=False)
        rows = self.rows.get(name)
        if rows is None:
            # A result before its section is out of order; the page has no
            # group to put it in and the section event is authoritative.
            return Change("result", name, accepted=False)

        row = rows.get(cid)
        if row is None:
            if self._seeded:
                # The last report decides which rows exist. A duplicate, a
                # stale event or an id from another section cannot add one.
                return Change("result", name, accepted=False)
            row = Row(
                name,
                cid,
                str(result.get("label") or cid),
                status,
                str(result.get("detail") or ""),
            )
            rows[cid] = row
            return Change("result", name, row, new_row=True)

        row.label = str(result.get("label") or row.label)
        row.status = status
        row.detail = str(result.get("detail") or "")
        return Change("result", name, row)

    # -- views ---------------------------------------------------------
    def counts(self) -> dict[str, int]:
        counts = {status.value: 0 for status in Status}
        for rows in self.rows.values():
            for row in rows.values():
                if not row.pending and row.status in counts:
                    counts[row.status] += 1
        return counts

    def total_rows(self) -> int:
        return sum(len(rows) for rows in self.rows.values())

    def reported_rows(self) -> int:
        return sum(
            1
            for rows in self.rows.values()
            for row in rows.values()
            if not row.pending
        )

    def payload(self) -> dict:
        """The rows as the same document `--json` prints, for the banner."""
        return {
            "ready": bool(self.ready),
            "counts": self.counts(),
            "sections": [
                {
                    "name": name,
                    "results": [
                        {
                            "status": row.status,
                            "id": row.cid,
                            "label": row.label,
                            "detail": row.detail,
                        }
                        for row in self.rows[name].values()
                        if not row.pending
                    ],
                }
                for name in self.sections
            ],
        }
