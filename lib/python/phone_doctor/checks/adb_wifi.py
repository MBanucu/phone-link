"""adb over Wi-Fi: is there a network (non-USB) adb transport?"""

from __future__ import annotations

from ..context import Context
from ..model import Result, ok, warn

SECTION = "[adb over wi-fi]"


def check(ctx: Context) -> list[Result]:
    for line in ctx.text(["adb", "devices"]).splitlines():
        fields = line.split()
        if len(fields) >= 2 and fields[1] == "device" and ":" in fields[0]:
            return [ok("network_transport", "network transport", fields[0])]
    return [
        warn(
            "network_transport",
            "network transport",
            "USB only (phone-adb-wifi)",
        )
    ]
