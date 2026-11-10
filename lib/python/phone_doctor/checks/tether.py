"""USB tethering: does the phone's rndis0 have an address?"""

from __future__ import annotations

from ..context import Context
from ..model import Result, ok, skip, warn

SECTION = "[usb tether]"


def check(ctx: Context) -> list[Result]:
    if not ctx.serial:
        return [skip("rndis0", "rndis0", "no adb")]
    output = ctx.adb("shell", "ip", "-4", "-o", "addr", "show", "rndis0")
    address = ""
    for line in output.splitlines():
        fields = line.split()
        if len(fields) >= 4:
            address = fields[3]
            break
    if address:
        return [ok("rndis0", "rndis0", address)]
    return [warn("rndis0", "rndis0", "no address (USB tether off)")]
