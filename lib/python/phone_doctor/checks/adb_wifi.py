"""adb over Wi-Fi: is there a network (non-USB) adb transport?"""

from __future__ import annotations

from ..context import Context
from ..model import Result, ok, warn

SECTION = "[adb over wi-fi]"


def _network_transport(ctx: Context) -> str | None:
    for line in ctx.text(["adb", "devices"]).splitlines():
        fields = line.split()
        if len(fields) >= 2 and fields[1] == "device" and ":" in fields[0]:
            return fields[0]
    return None


def check(ctx: Context) -> list[Result]:
    transport = _network_transport(ctx)
    if transport:
        return [ok("network_transport", "network transport", transport)]

    # A reboot rotates the wireless-debugging port, so a phone that is on the
    # network but missing from `adb devices` is usually unreachable rather than
    # gone: the new port is in its mDNS record, which is far quicker to read
    # than scanning the ephemeral range.
    address, announced = ctx.mdns_adb()
    if address:
        transport = ctx.adb_connect(address)
        if transport and ":" in transport:
            return [ok("network_transport", "network transport", transport)]
        return [
            warn(
                "network_transport",
                "network transport",
                f"{address} is advertised but adb connect failed",
            )
        ]

    if announced:
        # The name is out there and nothing resolved it: adbd is not listening,
        # so wireless debugging is off and the fix is on the phone.
        return [
            warn(
                "network_transport",
                "network transport",
                "announced with no address: wireless debugging is off on the "
                "phone (or turn it on from a cable with phone-adb-wifi)",
            )
        ]

    return [
        warn(
            "network_transport",
            "network transport",
            "USB only (phone-adb-wifi)",
        )
    ]
