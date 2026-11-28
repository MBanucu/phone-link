"""Helpers shared by the command modules after the split by feature.

One adb serial, one shell shape, one prompt and one escalation rule, so a
command that moved still behaves like the file it came from.
"""

from __future__ import annotations

import sys

from .. import actions, phone
from ..shell import capture, die, must


def _only_help(args: list[str], usage: str) -> None:
    for value in args:
        if value in ("-h", "--help"):
            print(usage, end="", file=sys.stderr)
            raise SystemExit(0)
        print(usage, end="", file=sys.stderr)
        die(f"unknown argument: {value}")


def _serial() -> str:
    serial = phone.phone_serial()
    if not serial:
        die("no phone attached (see adb devices)")
    return serial


def _shell(serial: str, *command: str) -> str:
    """One adb shell call, with CRs removed and the trailing newline trimmed."""
    return capture(["adb", "-s", serial, "shell", *command]).replace("\r", "")


def _first_line(text: str) -> str:
    lines = text.splitlines()
    return lines[0] if lines else ""


def _confirm_stdin(prompt: str) -> bool:
    """Ask on stdin when it is a terminal; anything else refuses."""
    if not sys.stdin.isatty():
        return False
    sys.stderr.write(prompt)
    sys.stderr.flush()
    return sys.stdin.readline().strip() in ("y", "Y", "yes", "YES")


def _tool(name: str):
    """A sibling command: PATH first, then the checkout next to this package."""
    return actions.binary(actions.BY_ID[name])


def _root(argv: list[str]) -> None:
    """Run one command as root: directly when we are, else through sudo."""
    if phone.is_root():
        must(argv)
    else:
        must(["sudo", "--", *argv])
