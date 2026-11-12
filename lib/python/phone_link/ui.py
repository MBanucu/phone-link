"""Phone-side UI helpers: keyguard state and uiautomator reads.

The proxy app builds its screen in code and is not debuggable, so there is no
resource id to address: the hierarchy is dumped with uiautomator and nodes are
tapped by their centre.
"""

from __future__ import annotations

import os
import re
import xml.etree.ElementTree as ET

from . import actions
from .shell import capture, status

REMOTE = os.environ.get("PHONE_UI_REMOTE") or "/sdcard/phone-link-ui.xml"
TIMEOUT = float(os.environ.get("PHONE_UI_TIMEOUT") or "20")

STATUS_WORDS = (
    "Proxy Running",
    "Failed to Start",
    "Proxy Stopped",
    "Starting",
    "Stopped",
)

BLOCKER_PATTERNS = (
    r"^Continue Anyway",
    r"^Allow",
    r"^OK",
    r"^Got it",
    r"^While using",
)


def unlock_bin() -> str | None:
    """The phone-unlock script, from PATH or next to this package."""
    path = actions.binary(actions.BY_ID["phone-unlock"])
    return path if os.access(path, os.X_OK) else None


def keyguard(serial: str, *, timeout: float = 60) -> bool:
    """True while the lock screen is showing."""
    output = capture(
        ["adb", "-s", serial, "shell", "dumpsys", "window", "policy"], timeout=timeout
    )
    for line in output.replace("\r", "").splitlines():
        match = re.match(r" *showing=(true|false)$", line)
        if match:
            return match.group(1) == "true"
    return False


def launch(serial: str) -> None:
    """Bring the app's activity to the front."""
    status(
        [
            "adb",
            "-s",
            serial,
            "shell",
            "monkey",
            "-p",
            os.environ.get("PHONE_PROXY_PKG") or "com.tokyoxpa3.androidproxy",
            "-c",
            "android.intent.category.LAUNCHER",
            "1",
        ]
    )


def dump(serial: str, path: str) -> bool:
    """Save the hierarchy; false when the app is not on screen."""
    if status(
        ["adb", "-s", serial, "shell", "uiautomator", "dump", REMOTE], timeout=TIMEOUT
    ) != 0:
        return False
    if status(["adb", "-s", serial, "pull", REMOTE, path]) != 0:
        return False
    try:
        if os.path.getsize(path) <= 0:
            return False
        with open(path, encoding="utf-8") as handle:
            if (os.environ.get("PHONE_PROXY_PKG") or "com.tokyoxpa3.androidproxy") not in handle.read():
                return False
    except OSError:
        return False
    return True


def _centre(bounds: str) -> tuple[int, int] | None:
    if not (bounds.startswith("[") and "][" in bounds):
        return None
    left, right = bounds.strip("[]").split("][")
    try:
        x1, y1 = (int(value) for value in left.split(","))
        x2, y2 = (int(value) for value in right.split(","))
    except ValueError:
        return None
    return (x1 + x2) // 2, (y1 + y2) // 2


def nodes(path: str):
    """Every addressable node as (class, text, x, y, element)."""
    tree = ET.parse(path)
    for node in tree.iter("node"):
        css = (node.get("class") or "").rsplit(".", 1)[-1]
        text = (node.get("text") or "").replace("\t", " ")
        point = _centre(node.get("bounds") or "")
        if point is None:
            continue
        yield css, text, point[0], point[1], node


def buttons(path: str) -> list[tuple[int, int, str]]:
    """Every button on screen, from any package (so dialogs are visible)."""
    return [
        (x, y, text)
        for css, text, x, y, _ in nodes(path)
        if css == "Button"
    ]


def button(path: str, pattern: str) -> tuple[int, int, str] | None:
    """The first button whose text matches the regex."""
    for x, y, text in buttons(path):
        if re.search(pattern, text):
            return x, y, text
    return None


def status_line(path: str) -> str:
    """The app's status line, if any."""
    for css, text, _, _, _ in nodes(path):
        if css == "TextView" and any(word in text for word in STATUS_WORDS):
            return text
    return ""


def blocker(path: str) -> tuple[int, int] | None:
    """A dialog button that lets a start proceed, in preference order."""
    for pattern in BLOCKER_PATTERNS:
        found = button(path, pattern)
        if found:
            return found[0], found[1]
    return None
