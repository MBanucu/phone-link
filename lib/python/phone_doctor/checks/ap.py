"""The link-only AP: the module's units, the forward drop and the phone.

The AP only carries the link to the phone, so what has to be true is narrow:
the DHCP-only dnsmasq answers (the profile has no NetworkManager shared
dnsmasq), the forward drop is installed (nothing may make the AP an uplink),
and the phone is associated. Everything here is skipped when `phoneLink.ap`
does not own the profile, because hotspot mode has none of these pieces.
"""

from __future__ import annotations

from ..context import Context
from ..model import Result, fail, ok, skip

SECTION = "[ap]"


def _unit(ctx: Context, unit: str, cid: str, label: str) -> Result:
    if not ctx.have("systemctl"):
        return skip(cid, label, "systemctl not installed")
    state = ctx.text(["systemctl", "is-active", unit]).strip()
    if state == "active":
        return ok(cid, label, "active")
    return fail(cid, label, f"{state or 'unknown'} ({unit})")


def _forward_drop(ctx: Context) -> Result:
    cid = "ap_noforward_rules"
    label = "ap forward drop"
    if not ctx.have("nft"):
        return skip(cid, label, "nft not installed")
    proc = ctx.run(["nft", "list", "table", "inet", "phone_link_ap"])
    output = (proc.stdout or "") if proc is not None else ""
    if proc is not None and proc.returncode == 0:
        for line in output.splitlines():
            if "drop" in line and ctx.ap_if in line:
                return ok(cid, label, f"{ctx.ap_if} dropped")
        return fail(cid, label, f"table inet phone_link_ap has no drop for {ctx.ap_if}")
    return fail(cid, label, "table inet phone_link_ap missing or unreadable")


def _station(ctx: Context) -> Result:
    cid = "ap_station"
    label = "ap station"
    if not ctx.have("iw"):
        return skip(cid, label, "iw not installed")
    dump = ctx.text(["iw", "dev", ctx.ap_if, "station", "dump"])
    stations = [
        line.strip()
        for line in dump.splitlines()
        if line.strip().startswith("Station ")
    ]
    if stations:
        return ok(cid, label, f"{len(stations)} on {ctx.ap_if}")
    return fail(cid, label, f"no phone associated on {ctx.ap_if}")


def check(ctx: Context) -> list[Result]:
    if not ctx.ap_declarative:
        return [skip("ap_units", "ap units", "phoneLink.ap is off")]

    return [
        _unit(
            ctx,
            "phone-link-ap-dhcp.service",
            "ap_dhcp",
            "ap dhcp",
        ),
        _unit(
            ctx,
            "phone-link-ap-noforward.service",
            "ap_noforward",
            "ap noforward",
        ),
        _forward_drop(ctx),
        _station(ctx),
    ]
