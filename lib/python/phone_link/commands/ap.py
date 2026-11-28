"""The laptop access point: profile, activation, teardown and rejoin.

These are the actions the GUI marks with a lock. Each one escalates through
sudo only when it has to: `phone-ap-up`, `phone-ap-down` and `phone-ap-create`
re-run themselves as root up front, while the read-only paths stay unprivileged.
"""

from __future__ import annotations

import os
import sys

from .. import phone, regdomain, settings
from ..shell import capture, die, have, log, must, run_both, status
from .common import _only_help, _tool


USAGE_AP_CREATE = """usage: phone-ap-create [--refresh] [--check]

Creates the NetworkManager AP profile phonelink with the SSID, WPA2 PSK
and address from PHONE_AP_SSID, PHONE_AP_PASS (in the secrets file) and
PHONE_AP_ADDRESS, on 5 GHz channel 149 at 80 MHz (PHONE_AP_BAND,
PHONE_AP_CHANNEL and PHONE_AP_CHANNEL_WIDTH override those). The PSK stays
out of the Nix store. --refresh rewrites an existing profile, e.g. after
rotating the password; --check only reports.

The profile is a link only: manual addressing, no gateway and no DNS, so
NetworkManager does not NAT the AP. A hand-made profile is refused unless
the module's DHCP-only dnsmasq and nft forward drop are installed; enable
phoneLink.ap and let the module own the access point instead.

When phoneLink.ap declares the profile, --refresh restarts the
NetworkManager-ensure-profiles unit instead of editing NetworkManager.
"""

# The module's link-only AP support. A hand-made profile is only usable when
# these are installed: the profile itself carries neither NAT nor DHCP, so
# without them the phone would get no address (or the old shared profile would
# bring the NAT loop back).
AP_DHCP_UNIT = "phone-link-ap-dhcp.service"
AP_NOFORWARD_UNIT = "phone-link-ap-noforward.service"

USAGE_AP_DOWN = """usage: phone-ap-down [--client] [--help]

Stops the PhoneLink access point. By default the laptop then joins the phone's
own hotspot (PHONE_HOTSPOT_CON), as before. --client stops the AP and does not
join the hotspot, leaving the radio free for NetworkManager to scan for and
join a normal network. Nothing is persisted: a reboot returns to the configured
boot state. Needs root.

With phoneLink.ap.role = "external" the AP is another host: this command
explains that and changes nothing, because neither the AP nor the laptop's
client link belongs to phoneLink.
"""

USAGE_AP_DELETE = """usage: phone-ap-delete [--yes] [--check]

Deletes the NetworkManager connection phonelink (the laptop AP) after
bringing it down if it is active. --check only reports; --yes skips the
confirmation. Needs root.
"""


def _profile_exists() -> bool:
    names = capture(["nmcli", "-t", "-f", "NAME", "con", "show"]).splitlines()
    return settings.PHONE_AP_CON in names


def _active_device() -> str:
    lines = capture(
        ["nmcli", "-t", "-f", "NAME,DEVICE", "con", "show", "--active"]
    ).splitlines()
    for line in lines:
        name, _, device = line.partition(":")
        if name == settings.PHONE_AP_CON:
            return device
    return ""


def _ap_method() -> str:
    """The profile's IPv4 method, or "" when it cannot be read."""
    return capture(
        [
            "nmcli",
            "-g",
            "ipv4.method",
            "connection",
            "show",
            settings.PHONE_AP_CON,
        ]
    )


def _ap_link_units() -> bool:
    """Whether the module's DHCP-only and no-forward AP units are installed."""
    return status(["systemctl", "cat", AP_DHCP_UNIT, AP_NOFORWARD_UNIT]) == 0


def _refuse_hand_made_ap() -> None:
    die(
        "the link-only access point needs the NixOS module: set "
        "phoneLink.ap.enable = true and rebuild. phone-ap-create no longer "
        "writes NetworkManager's shared (NAT) profile, and without the "
        "module's DHCP-only dnsmasq and nft forward drop a hand-made profile "
        "would not be usable. Delete an old profile with phone-ap-delete"
    )


def _request_ap_rejoin() -> None:
    """Ask the rejoin watchdog for the association now, without the throttle.

    The state file records the last attempt; it is what keeps the timer quiet
    for five minutes. A switch-on is a deliberate new AP, so the window starts
    over. The unit does not exist with phoneLink.ap.rejoin = false, and it
    no-ops without a station or USB adb, so every failure here is ignored: the
    AP is up either way and the watchdog will still catch up on its own.

    `--no-block` matters: the unit waits up to 30 s for the station, and a
    switch-on with the phone away must not hold the command for that long. The
    watchdog does the waiting, and the panel's own probe shows the join.
    """
    try:
        os.unlink(settings.PHONE_AP_REJOIN_STATE)
    except OSError:
        pass
    status(["systemctl", "start", "--no-block", settings.PHONE_AP_REJOIN_UNIT])


def _ap_is_external() -> bool:
    """Whether the AP belongs to another host (`phoneLink.ap.role`)."""
    return settings.PHONE_AP_ROLE == "external"


def _ap_channel_verdict() -> regdomain.Verdict | None:
    """Read the regulatory state of the configured AP channel, read-only.

    Returns None when `iw` is absent: the check must not block a setup that
    works, and the caller keeps the activation path unchanged.
    """
    if not have("iw"):
        return None
    channel = (
        int(settings.PHONE_AP_CHANNEL) if settings.PHONE_AP_CHANNEL.isdigit() else 0
    )
    if not channel:
        return None
    return regdomain.probe(
        settings.PHONE_AP_BAND,
        channel,
        interface=settings.PHONE_AP_IF,
        capture=capture,
    )


def _preflight_ap_channel() -> regdomain.Verdict | None:
    """Refuse a channel the domain does not allow, before NetworkManager waits.

    The supplicant timeout is about 25 s and its message ("802.1X supplicant
    took too long to authenticate") names the wrong subsystem.  This is the
    same check the doctor reports as `ap_channel`.
    """
    verdict = _ap_channel_verdict()
    if verdict is None or verdict.allowed is not False:
        return verdict
    what = regdomain.channel_label(
        settings.PHONE_AP_BAND, int(settings.PHONE_AP_CHANNEL)
    )
    die(
        f"{what} is {verdict.reason} in "
        f"{regdomain.country_label(verdict.country)}, so NetworkManager "
        "cannot start the AP here (it would end in the 802.1X supplicant "
        f"timeout). Fix: {regdomain.remediation(verdict.country)}. "
        "Not waiting for the supplicant timeout"
    )
    return verdict


# The activation failures the issue observed when wpa_supplicant is stale:
# the domain allows the channel, but the supplicant's failed AP state survives
# a regulatory change until NetworkManager restarts it.
_ACTIVATION_FAILED_AP = (
    "802.1x supplicant took too long to authenticate",
    "failed to start ap functionality",
)


def _ap_activation_failed(
    code: int, output: str, verdict: regdomain.Verdict | None
) -> None:
    """Report an `nmcli connection up` failure, adding the stale-supplicant hint."""
    if output:
        log(output)
    if (
        verdict is not None
        and verdict.allowed is True
        and any(needle in output.lower() for needle in _ACTIVATION_FAILED_AP)
    ):
        what = regdomain.channel_label(
            settings.PHONE_AP_BAND, int(settings.PHONE_AP_CHANNEL)
        )
        log(
            f"hint: {what} is allowed in "
            f"{regdomain.country_label(verdict.country)}, so this is not the "
            "regulatory domain. A failed wpa_supplicant AP state can survive "
            "an `iw reg set`; restart NetworkManager to clear it: "
            "sudo systemctl restart NetworkManager"
        )
    raise SystemExit(code)


def _ap_fallback_enabled() -> bool:
    """Whether the module turned on the one-shot 2.4 GHz fallback."""
    return settings.PHONE_AP_FALLBACK == "1"


def _try_ap_fallback(reason: str) -> bool:
    """Run the shared 2.4 GHz fallback script once; False leaves the caller to die.

    The script (and the boot unit) own the one-attempt-per-boot state file and
    the profile change, so the command and the unattended path cannot loop or
    disagree.  It reads no secret: NetworkManager already holds the PSK.
    """
    if not _ap_fallback_enabled():
        return False
    tool = settings.PHONE_AP_FALLBACK_TOOL
    if not os.access(tool, os.X_OK):
        log(
            f"the 2.4 GHz fallback is enabled but {tool} is missing or not "
            "executable; rebuild the module or disable phoneLink.ap.fallback"
        )
        return False
    log(f"trying the 2.4 GHz fallback (one attempt per boot): {reason}")
    code, output = run_both([tool, "--now", "--reason", reason])
    if output:
        log(output)
    return code == 0


def _restore_declared_ap_profile() -> None:
    """Undo a runtime fallback so the next switch-on tries 5 GHz again."""

    if not _ap_fallback_enabled():
        return
    if not os.path.exists(settings.PHONE_AP_FALLBACK_STATE):
        return
    code, output = run_both(
        [
            "nmcli",
            "connection",
            "modify",
            settings.PHONE_AP_CON,
            "802-11-wireless.band",
            settings.PHONE_AP_BAND,
            "802-11-wireless.channel",
            settings.PHONE_AP_CHANNEL,
            "802-11-wireless.channel-width",
            settings.PHONE_AP_CHANNEL_WIDTH,
        ]
    )
    if output:
        log(output)
    if code != 0:
        log(
            "could not restore the declared AP profile after the 2.4 GHz "
            "fallback; the next switch-on keeps 2.4 GHz until a reboot"
        )
        return
    try:
        os.unlink(settings.PHONE_AP_FALLBACK_STATE)
    except OSError:
        pass
    log(
        "AP profile restored to the declared band/channel; the next "
        "phone-ap-up tries 5 GHz again"
    )


def phone_ap_up(args: list[str]) -> int:
    """Bring up the laptop access point the phone joins as a Wi-Fi client."""
    phone.as_root("phone-ap-up", args)

    if _ap_is_external():
        # Nothing on this host is the AP.  The one part that still applies is
        # the USB nudge: the external AP may be link-only too, so the phone can
        # be sitting beside it with auto-join disabled.  Asking the watchdog now
        # is safe when it is throttled, absent or there is no USB device.
        _request_ap_rejoin()
        log(
            'AP is external (phoneLink.ap.role = "external"); this host does '
            "not own it and has nothing to activate. The laptop joins it as a "
            "client; the phone is nudged back over USB if it is away."
        )
        return 0

    if "* AP" not in capture(["iw", "list"]):
        die("driver reports no AP mode")
    if capture(["nmcli", "-g", "wifi.backend"]) == "iwd":
        die("NetworkManager uses iwd; AP mode needs wpa_supplicant")

    verdict = _ap_channel_verdict()
    blocked = verdict is not None and verdict.allowed is False
    if blocked and not _ap_fallback_enabled():
        # No fallback to try: keep the precise refusal and its remediation.
        _preflight_ap_channel()

    if not _profile_exists():
        if phone.ap_declarative():
            log(
                f"profile {settings.PHONE_AP_CON} missing; reloading it from phoneLink.ap"
            )
            if status(["systemctl", "restart", settings.PHONE_AP_ENSURE_UNIT]) != 0:
                die(f"could not restart {settings.PHONE_AP_ENSURE_UNIT}")
            if not _profile_exists():
                die(f"{settings.PHONE_AP_CON} is still missing after the reload")
        else:
            log(
                f"profile {settings.PHONE_AP_CON} missing; creating it from "
                f"{settings.PHONE_SECRETS}"
            )
            if status([_tool("phone-ap-create")]) != 0:
                die(
                    f"could not create profile {settings.PHONE_AP_CON} "
                    "(run phone-ap-create)"
                )

    fallback_up = False
    if blocked:
        what = regdomain.channel_label(
            settings.PHONE_AP_BAND, int(settings.PHONE_AP_CHANNEL)
        )
        reason = (
            f"{what} is {verdict.reason} in {regdomain.country_label(verdict.country)}"
        )
        if _try_ap_fallback(reason):
            fallback_up = True
        else:
            _preflight_ap_channel()
    else:
        code, output = run_both(["nmcli", "connection", "up", settings.PHONE_AP_CON])
        if code != 0:
            if _try_ap_fallback(output or f"nmcli connection up exited {code}"):
                fallback_up = True
            else:
                _ap_activation_failed(code, output, verdict)
        if output:
            log(output)
    _request_ap_rejoin()
    must(["ip", "-4", "-br", "addr", "show", settings.PHONE_AP_IF])
    if fallback_up:
        log(
            "AP up on the 2.4 GHz fallback "
            f"(channel {settings.PHONE_AP_FALLBACK_CHANNEL} at "
            f"{settings.PHONE_AP_FALLBACK_WIDTH} MHz). 5 GHz is retried at the "
            "next boot or after phone-ap-down."
        )
    else:
        log("AP up. The phone must have Wi-Fi (client) on, not the hotspot.")
    return 0


def phone_ap_down(args: list[str]) -> int:
    """Stop the access point, then optionally rejoin the phone's own hotspot."""
    client_only = False
    for value in args:
        if value == "--client":
            client_only = True
        elif value in ("-h", "--help"):
            print(USAGE_AP_DOWN, end="", file=sys.stderr)
            return 0
        else:
            print(USAGE_AP_DOWN, end="", file=sys.stderr)
            die(f"unknown argument: {value}")

    if _ap_is_external():
        log(
            'AP is external (phoneLink.ap.role = "external"); this host does '
            "not own it and phone-ap-down does not stop it. The laptop's "
            "client link is unchanged; leave the external AP on so the phone "
            "stays associated."
        )
        return 0

    phone.as_root("phone-ap-down", args)

    if status(["nmcli", "connection", "down", settings.PHONE_AP_CON]) != 0:
        die(f"could not stop {settings.PHONE_AP_CON}")

    # A fallback changed only the runtime profile, so put the declared
    # band/channel back while it is down: the next phone-ap-up tries 5 GHz
    # again instead of silently staying on the slow band until a reboot.
    _restore_declared_ap_profile()

    if client_only:
        log(
            "AP down; Wi-Fi is free for NetworkManager to scan and join a "
            "normal network (the phone link is down by design)"
        )
    elif status(["nmcli", "connection", "up", settings.PHONE_HOTSPOT_CON]) != 0:
        log(
            f"AP down; could not join {settings.PHONE_HOTSPOT_CON} "
            "(is the phone sharing it?)"
        )
    else:
        log(f"AP down; joined the phone hotspot {settings.PHONE_HOTSPOT_CON}")
    must(["nmcli", "-t", "-f", "NAME,DEVICE", "con", "show", "--active"])
    return 0


def phone_ap_create(args: list[str]) -> int:
    """Create or refresh the laptop AP profile from the root-only secrets."""
    usage_args = [value for value in args if value not in ("--refresh", "--check")]
    _only_help(usage_args, USAGE_AP_CREATE)
    refresh = "--refresh" in args
    check_only = "--check" in args

    if _ap_is_external():
        log(
            'AP is external (phoneLink.ap.role = "external"); there is no '
            "local profile to create or refresh. Configure the external AP "
            "itself as link-only and reserve proxyHost for the phone."
        )
        return 0

    if check_only:
        exists = _profile_exists()
        log(
            f"{settings.PHONE_AP_CON} exists"
            if exists
            else f"{settings.PHONE_AP_CON} is missing"
        )
        if phone.ap_declarative():
            log(f"{settings.PHONE_AP_CON} is declared by phoneLink.ap")
            log(
                f"PSK source: {settings.PHONE_SECRETS} "
                f"(read by {settings.PHONE_AP_ENSURE_UNIT} as root)"
            )
        else:
            method = _ap_method() if exists else ""
            if method == "shared":
                log(
                    f"{settings.PHONE_AP_CON} uses ipv4.method shared (NAT); "
                    "it must be rebuilt link-only"
                )
            elif method:
                log(f"{settings.PHONE_AP_CON} uses ipv4.method {method}")
            log(
                "link-only units: installed"
                if _ap_link_units()
                else "link-only units: missing (phoneLink.ap is required)"
            )
            if os.access(settings.PHONE_SECRETS, os.R_OK):
                log(f"PSK source: {settings.PHONE_SECRETS} (PHONE_AP_PASS)")
            else:
                log(
                    f"PSK source: {settings.PHONE_SECRETS} not readable (run with sudo)"
                )
        return 0 if exists else 1

    if phone.ap_declarative():
        if _profile_exists() and not refresh:
            log(f"{settings.PHONE_AP_CON} is declared by phoneLink.ap and exists")
            return 0
        phone.as_root("phone-ap-create", args)
        log(f"reloading {settings.PHONE_AP_CON} from phoneLink.ap")
        if status(["systemctl", "restart", settings.PHONE_AP_ENSURE_UNIT]) != 0:
            die(f"could not restart {settings.PHONE_AP_ENSURE_UNIT}")
        if not _profile_exists():
            die(f"{settings.PHONE_AP_CON} is still missing after the reload")
        log(f"{settings.PHONE_AP_CON} reloaded; run phone-ap-up to activate it")
        return 0

    existing = _profile_exists()
    method = _ap_method() if existing else ""

    # The non-declarative profile is link-only as well. It is only usable with
    # the module's DHCP server and forward drop, so refuse rather than write a
    # profile that is either unreachable (no DHCP) or, as before, a NAT uplink.
    if not _ap_link_units():
        if existing and method != "shared" and not refresh:
            log(f"{settings.PHONE_AP_CON} already exists and is link-only")
            return 0
        _refuse_hand_made_ap()

    if existing and not refresh and method != "shared":
        log(
            f"{settings.PHONE_AP_CON} already exists (use --refresh to rewrite its PSK)"
        )
        return 0
    if existing and method == "shared":
        log(f"rewriting {settings.PHONE_AP_CON} as a link-only profile (no NAT)")

    phone.as_root("phone-ap-create", args)
    password = phone.ap_pass()

    base = [
        "ssid",
        settings.PHONE_AP_SSID,
        "802-11-wireless.mode",
        "ap",
        "802-11-wireless.band",
        settings.PHONE_AP_BAND,
        "802-11-wireless.channel",
        settings.PHONE_AP_CHANNEL,
        "802-11-wireless.channel-width",
        settings.PHONE_AP_CHANNEL_WIDTH,
        "wifi-sec.key-mgmt",
        "wpa-psk",
        "wifi-sec.psk",
        password,
        "ipv4.method",
        "manual",
        "ipv4.addresses",
        settings.PHONE_AP_ADDRESS,
    ]
    if _profile_exists():
        log(f"refreshing {settings.PHONE_AP_CON} from {settings.PHONE_SECRETS}")
        if (
            status(
                [
                    "nmcli",
                    "connection",
                    "modify",
                    settings.PHONE_AP_CON,
                    *base,
                ]
            )
            != 0
        ):
            die("nmcli connection modify failed")
    else:
        log(f"creating {settings.PHONE_AP_CON} from {settings.PHONE_SECRETS}")
        if (
            status(
                [
                    "nmcli",
                    "connection",
                    "add",
                    "type",
                    "wifi",
                    "ifname",
                    settings.PHONE_AP_IF,
                    "con-name",
                    settings.PHONE_AP_CON,
                    "autoconnect",
                    "no",
                    *base,
                ]
            )
            != 0
        ):
            die("nmcli connection add failed")

    if not _profile_exists():
        die(f"{settings.PHONE_AP_CON} is still missing after create")
    mode = capture(
        [
            "nmcli",
            "-g",
            "802-11-wireless.mode",
            "connection",
            "show",
            settings.PHONE_AP_CON,
        ]
    )
    if mode != "ap":
        die(f"{settings.PHONE_AP_CON} is not in AP mode (got: {mode or 'unknown'})")
    log(f"{settings.PHONE_AP_CON} is ready; run phone-ap-up to activate it")
    return 0


def phone_ap_delete(args: list[str]) -> int:
    """Delete the laptop's PhoneLink access-point profile."""
    assume_yes = False
    check_only = False
    for value in args:
        if value in ("-y", "--yes"):
            assume_yes = True
        elif value == "--check":
            check_only = True
        elif value in ("-h", "--help"):
            print(USAGE_AP_DELETE, end="", file=sys.stderr)
            return 0
        else:
            print(USAGE_AP_DELETE, end="", file=sys.stderr)
            die(f"unknown argument: {value}")

    if _ap_is_external():
        log(
            'AP is external (phoneLink.ap.role = "external"); there is no '
            "local profile this host owns, so nothing is deleted."
        )
        return 0

    if not _profile_exists():
        log(f"{settings.PHONE_AP_CON} is not configured; nothing to delete")
        return 0
    if phone.ap_declarative():
        log(
            f"note: {settings.PHONE_AP_CON} is declared by phoneLink.ap; "
            "it returns at the next boot"
        )

    device = _active_device()
    if check_only:
        suffix = f" and is active on {device}" if device else ""
        log(f"{settings.PHONE_AP_CON} exists{suffix}")
        return 0

    phone.as_root("phone-ap-delete", args)

    if not assume_yes:
        prompt = f"Delete the AP profile {settings.PHONE_AP_CON}? [y/N] "
        if not sys.stdin.isatty():
            die("refusing to delete without --yes (not a terminal)")
        sys.stderr.write(prompt)
        sys.stderr.flush()
        if sys.stdin.readline().strip() not in ("y", "Y", "yes", "YES"):
            log("aborted")
            return 1

    if device:
        log(f"bringing {settings.PHONE_AP_CON} down (active on {device})")
        status(["nmcli", "connection", "down", settings.PHONE_AP_CON])

    log(f"deleting {settings.PHONE_AP_CON}")
    if status(["nmcli", "connection", "delete", settings.PHONE_AP_CON]) != 0:
        die("nmcli connection delete failed")
    if _profile_exists():
        die(f"{settings.PHONE_AP_CON} still exists after delete")
    log(f"{settings.PHONE_AP_CON} deleted (the phone's saved network is untouched)")
    return 0
