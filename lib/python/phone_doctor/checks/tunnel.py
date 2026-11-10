"""Tunnel checks: is phone-tun active and does its routing rule exist?"""

from __future__ import annotations

from ..context import Context
from ..model import Result, ok, warn

SECTION = "[tunnel]"


def check(ctx: Context) -> list[Result]:
    state = ctx.text(["systemctl", "is-active", "phone-tun.service"]).strip()
    if state != "active":
        return [
            warn(
                "phone_tun",
                "phone-tun",
                f"{state or 'unknown'} (the timer starts it when the proxy answers)",
            )
        ]

    results = [ok("phone_tun", "phone-tun", "active")]
    if "2022" in ctx.text(["ip", "rule", "show"]):
        results.append(ok("tunnel_route", "tunnel route", "table 2022"))
    else:
        results.append(warn("tunnel_route", "tunnel route", "no 2022 ip rule"))
    return results
