"""This repository's own app: installed, and will it come back at boot?

The app in `android/` is the one whose boot restart depends on things outside
itself — the device-idle allowlist and background location — so a phone that
serves `200` today can still come up with no listener tomorrow. The check names
exactly which of those facts is missing; `phone-proxy-boot` fixes them.
"""

from __future__ import annotations

import re

from ..context import Context
from ..model import Result, fail, ok, warn

SECTION = "[app]"

APP = "org.phonelink.proxy"
SERVICE = f"{APP}/.ProxyService"


def _installed(ctx: Context) -> bool:
    text = ctx.adb("shell", "pm", "path", APP)
    return any(line.startswith("package:") for line in text.splitlines())


def _auto_start(ctx: Context) -> str:
    """The app's stored auto_start, which its service prints for dumpsys."""
    text = ctx.adb("shell", "dumpsys", "activity", "service", SERVICE)
    match = re.search(r"auto-start\s+(true|false)", text)
    return match.group(1) if match else ""


def _whitelisted(ctx: Context) -> bool:
    return f",{APP}," in ctx.adb("shell", "dumpsys", "deviceidle", "whitelist")


def _background_location(ctx: Context) -> str:
    text = ctx.adb("shell", "dumpsys", "package", APP)
    match = re.search(r"ACCESS_BACKGROUND_LOCATION: granted=(true|false)", text)
    return match.group(1) if match else ""


def check(ctx: Context) -> list[Result]:
    if not ctx.serial:
        return [warn("app_installed", "phone-link app", "unknown (no adb)")]

    if not _installed(ctx):
        return [
            fail(
                "app_installed",
                "phone-link app",
                "not installed (phone-proxy-install <apk>)",
            )
        ]

    results: list[Result] = [ok("app_installed", "phone-link app", APP)]

    auto_start = _auto_start(ctx)
    whitelisted = _whitelisted(ctx)
    background = _background_location(ctx)
    unknown = not auto_start or not background

    missing: list[str] = []
    if auto_start == "false":
        missing.append("auto_start is off")
    if not whitelisted:
        missing.append("not on the battery allowlist")
    if background == "false":
        missing.append("background location is not granted")

    if missing:
        results.append(
            fail(
                "app_boot",
                "restarts at boot",
                "; ".join(missing) + " (run phone-proxy-boot)",
            )
        )
    elif unknown:
        results.append(
            warn(
                "app_boot",
                "restarts at boot",
                "allowlist yes, but "
                + ("auto_start could not be read (service not running)"
                   if not auto_start else "background location could not be read"),
            )
        )
    else:
        results.append(
            ok(
                "app_boot",
                "restarts at boot",
                "auto_start on, allowlisted, background location granted",
            )
        )
    return results
