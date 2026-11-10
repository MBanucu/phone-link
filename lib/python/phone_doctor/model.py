"""The small result model every check module returns."""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum


class Status(str, Enum):
    OK = "ok"
    WARN = "warn"
    FAIL = "fail"
    SKIP = "skip"


@dataclass(frozen=True)
class Result:
    status: Status
    cid: str
    label: str
    detail: str


def ok(cid: str, label: str, detail: str) -> Result:
    return Result(Status.OK, cid, label, detail)


def warn(cid: str, label: str, detail: str) -> Result:
    return Result(Status.WARN, cid, label, detail)


def fail(cid: str, label: str, detail: str) -> Result:
    return Result(Status.FAIL, cid, label, detail)


def skip(cid: str, label: str, detail: str) -> Result:
    return Result(Status.SKIP, cid, label, detail)
