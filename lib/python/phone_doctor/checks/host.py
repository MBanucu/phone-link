"""Host-side checks: forwarding, the AP profile/address and the resolver."""

from __future__ import annotations

from pathlib import Path

from ..context import Context
from ..model import Result, fail, ok, warn

SECTION = "[host]"


def _ap_address(ctx: Context) -> str:
    for line in ctx.text(["ip", "-4", "-br", "addr", "show", ctx.ap_if]).splitlines():
        fields = line.split()
        if len(fields) >= 3:
            return fields[2]
    return ""


def _nameservers(ctx: Context) -> list[str]:
    try:
        lines = Path(ctx.resolv).read_text().splitlines()
    except OSError:
        return []
    servers: list[str] = []
    for line in lines:
        fields = line.split()
        if len(fields) >= 2 and fields[0] == "nameserver":
            servers.append(fields[1])
    return servers


def check(ctx: Context) -> list[Result]:
    results: list[Result] = []

    forward = ctx.text(["sysctl", "-n", "net.ipv4.ip_forward"]).strip()
    if forward == "1":
        results.append(ok("ip_forward", "ip_forward", "1"))
    else:
        results.append(
            fail(
                "ip_forward",
                "ip_forward",
                f"{forward or 'unknown'} (set net.ipv4.ip_forward = 1)",
            )
        )

    if ctx.profile_exists():
        results.append(ok("ap_profile", "ap profile", ctx.ap_con))
    else:
        results.append(
            warn(
                "ap_profile",
                "ap profile",
                f"{ctx.ap_con} missing (run phone-ap-create, or hotspot mode)",
            )
        )

    address = _ap_address(ctx)
    if ctx.profile_exists():
        if address:
            results.append(ok("ap_address", "ap address", f"{ctx.ap_if} {address}"))
        else:
            results.append(
                fail("ap_address", "ap address", f"{ctx.ap_if} has no IPv4 (AP down)")
            )
    else:
        results.append(
            warn(
                "ap_address",
                "ap address",
                f"{ctx.ap_if} has no IPv4 (hotspot mode)",
            )
        )

    servers = _nameservers(ctx)
    joined = " ".join(servers)
    if joined:
        joined += " "
    if "1.1.1.1" in servers and "9.9.9.9" in servers:
        results.append(ok("resolver", "resolver", joined))
    else:
        results.append(
            warn(
                "resolver",
                "resolver",
                f"{joined or 'none'} (the module pins 1.1.1.1/9.9.9.9)",
            )
        )
    return results
