"""Phone-side checks: adb, keyguard, address and default route."""

from __future__ import annotations

import re

from ..context import Context
from ..model import Result, fail, ok, skip, warn
from phone_link.phone import WIFI_RECONNECT_GLOBALS

SECTION = "[phone]"


def _wifi_reconnect(ctx: Context) -> Result:
    """Report the globals that let the phone rejoin unattended.

    Stock Android settings are the default and are not a failure: the doctor
    only says that an explicit `phone-wifi-reconnect` is what changes them.
    """
    values = [
        (name, ctx.adb("shell", "settings", "get", "global", name).strip(), wanted)
        for name, wanted in WIFI_RECONNECT_GLOBALS
    ]
    rendered = ", ".join(f"{name}={value or 'unset'}" for name, value, _ in values)
    if all(value == wanted for _, value, wanted in values):
        return ok("wifi_reconnect", "wifi reconnect", f"{rendered} (recommended)")
    return warn(
        "wifi_reconnect",
        "wifi reconnect",
        f"{rendered} (run phone-wifi-reconnect to set both)",
    )


def _keyguard(ctx: Context) -> str:
    text = ctx.adb("shell", "dumpsys window policy")
    match = re.search(r"^\s*showing=(true|false)\s*$", text, re.MULTILINE)
    return match.group(1) if match else ""


def check(ctx: Context) -> list[Result]:
    results: list[Result] = []
    serial = ctx.serial
    if serial:
        results.append(ok("adb_device", "adb device", serial))
    elif ctx.serial_error:
        results.append(fail("adb_device", "adb device", ctx.serial_error))
    else:
        results.append(fail("adb_device", "adb device", "none (see adb devices)"))

    if not serial:
        return results + [
            skip("wifi_reconnect", "wifi reconnect", "no adb"),
            skip("phone_unlocked", "phone unlocked", "no adb"),
            skip("phone_address", "phone address", "no adb"),
            skip("phone_default", "phone default", "no adb"),
        ]

    results.append(_wifi_reconnect(ctx))

    showing = _keyguard(ctx)
    if showing == "false":
        results.append(ok("phone_unlocked", "phone unlocked", "yes"))
    elif showing == "true":
        results.append(
            warn("phone_unlocked", "phone unlocked", "no (run phone-unlock)")
        )
    else:
        results.append(warn("phone_unlocked", "phone unlocked", "unknown"))

    target = ctx.target_ip
    ips = ctx.phone_ips()
    if target in ips:
        results.append(ok("phone_address", "phone address", target))
    else:
        results.append(
            fail(
                "phone_address",
                "phone address",
                f"{target} not on the phone (has: {' '.join(ips)} )",
            )
        )

    route = ""
    for line in ctx.adb("shell", "ip", "route", "show", "default").splitlines():
        if line.strip():
            route = line.strip()
            break
    if route:
        results.append(ok("phone_default", "phone default", route))
    else:
        results.append(
            fail(
                "phone_default",
                "phone default",
                "no default route (mobile data off?)",
            )
        )
    return results
