"""The link-only AP: the module's units, the forward drop and the phone.

The AP only carries the link to the phone, so what has to be true is narrow:
the DHCP-only dnsmasq answers (the profile has no NetworkManager shared
dnsmasq), the forward drop is installed (nothing may make the AP an uplink),
and the phone is associated. Everything here is skipped when `phoneLink.ap`
does not own the profile, because hotspot mode has none of these pieces.
"""

from __future__ import annotations

from phone_link import regdomain

from ..context import Context
from ..model import Result, fail, ok, skip, warn

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
    nft = ctx.nft
    if nft is None:
        return skip(cid, label, "nft not installed")
    proc = ctx.run([nft, "list", "table", "inet", "phone_link_ap"])
    output = (proc.stdout or "") if proc is not None else ""
    if proc is not None and proc.returncode == 0:
        for line in output.splitlines():
            if "drop" in line and ctx.ap_if in line:
                return ok(cid, label, f"{ctx.ap_if} dropped")
        return fail(cid, label, f"table inet phone_link_ap has no drop for {ctx.ap_if}")
    return fail(cid, label, "table inet phone_link_ap missing or unreadable")


def _channel(ctx: Context) -> Result:
    """Whether the configured AP channel is usable in the current domain.

    Independent of the AP: it reads `iw`, not the profile's activation, so it
    answers the fresh-boot case where nothing is up yet.  The parse is shared
    with `phone-ap-up`, so the command and the doctor cannot disagree.
    """
    cid = "ap_channel"
    label = "ap channel"
    if not ctx.have("iw"):
        return skip(cid, label, "iw not installed")
    verdict = regdomain.probe(
        ctx.ap_band,
        ctx.ap_channel,
        interface=ctx.ap_if,
        capture=ctx.text,
    )
    what = regdomain.channel_label(ctx.ap_band, ctx.ap_channel)
    if verdict.allowed is None:
        return skip(cid, label, f"cannot read the regulatory domain for {what}")
    if verdict.allowed:
        return ok(
            cid,
            label,
            f"{what} allowed in {regdomain.country_label(verdict.country)}",
        )
    return warn(
        cid,
        label,
        f"{what} is {verdict.reason} in "
        f"{regdomain.country_label(verdict.country)}; "
        f"{regdomain.remediation(verdict.country)}",
    )


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
    # The AP can be on air with its SSID and no station: the phone dropped the
    # link and the quickest recovery is the existing connect command, not a
    # reboot. Only claim that when the interface really advertises the SSID.
    info = ctx.text(["iw", "dev", ctx.ap_if, "info"])
    ssid_up = any(line.strip() == f"ssid {ctx.ap_ssid}" for line in info.splitlines())
    if ssid_up:
        return warn(
            cid,
            label,
            f"no phone associated on {ctx.ap_if}; run phone-wifi-connect {ctx.ap_ssid}",
        )
    return fail(cid, label, f"no phone associated on {ctx.ap_if}")


def _external_link(ctx: Context) -> Result:
    """Whether this laptop is a client of the external AP.

    There is no local AP to be down, so this never reports "AP down": an
    absent client link is a setup step on this host, not a dead access point.
    """
    cid = "ap_link"
    label = "external ap link"
    if not ctx.have("iw"):
        return skip(cid, label, "iw not installed")
    link = ctx.text(["iw", "dev", ctx.ap_if, "link"])
    if "Connected to" not in link:
        return warn(
            cid,
            label,
            f"laptop is not a client of {ctx.ap_ssid} on {ctx.ap_if} "
            "(the external AP is up independently; join it in NetworkManager)",
        )
    ssid = ""
    for line in link.splitlines():
        stripped = line.strip()
        if stripped.startswith("SSID: "):
            ssid = stripped.removeprefix("SSID: ")
            break
    if ssid and ssid != ctx.ap_ssid:
        return warn(
            cid,
            label,
            f"laptop is on {ssid}, not {ctx.ap_ssid}",
        )
    return ok(cid, label, f"client of {ssid or ctx.ap_ssid} on {ctx.ap_if}")


def _external_station(ctx: Context) -> Result:
    """Whether the phone holds its reservation on the external AP.

    The laptop cannot see the external AP's station table, so the phone's own
    address list is the evidence; it is read over adb.  A missing association
    mirrors the local role's warning (the link can come back on its own or be
    re-asserted) instead of failing the setup or blaming the AP.
    """
    cid = "ap_station"
    label = "ap station"
    if ctx.serial is None:
        return skip(cid, label, "no adb")
    target = ctx.proxy_host
    ips = ctx.phone_ips()
    if target in ips:
        return ok(cid, label, f"phone {target} on {ctx.ap_ssid}")
    return warn(
        cid,
        label,
        f"phone {target} is not on {ctx.ap_ssid} "
        f"(has: {' '.join(ips) or 'none'}; run phone-wifi-connect {ctx.ap_ssid})",
    )


def check(ctx: Context) -> list[Result]:
    if ctx.ap_external:
        role = ok(
            "ap_role",
            "ap role",
            "external (another host owns the AP; the laptop is a client)",
        )
        channel = skip(
            "ap_channel",
            "ap channel",
            "external AP; this host does not own the channel",
        )
        return [role, channel, _external_link(ctx), _external_station(ctx)]

    role = ok("ap_role", "ap role", "local (this laptop owns the AP)")
    if not ctx.ap_declarative:
        return [
            role,
            skip("ap_channel", "ap channel", "phoneLink.ap is off"),
            skip("ap_units", "ap units", "phoneLink.ap is off"),
        ]

    return [
        role,
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
        _channel(ctx),
        _station(ctx),
    ]
