"""The privileged network commands: forwarding, tunnel, AP and Wi-Fi link.

These are the actions the GUI marks with a lock. Each one escalates through
sudo only when it has to, exactly as the bash versions did: `phone-ap-up` and
`phone-tunnel-run` re-run themselves as root up front, while the forwarding and
tunnel repairs wrap just the `sysctl`/`systemctl` call.
"""

from __future__ import annotations

import glob
import hashlib
import os
import re
import secrets as random_secrets
import shlex
import shutil
import sys
import tempfile
import time

from .. import actions, phone, settings
from ..shell import capture, die, log, must, run, run_text, status

USAGE_FORWARDING = """usage: phone-fix-forwarding [--check]

Enables net.ipv4.ip_forward for the running kernel. --check only reports.
"""

USAGE_TUNNEL = """usage: phone-fix-tunnel [--check]

Starts phone-tun.service (or restarts it when the 2022 route is missing) and
waits for the route. --check only reports.
"""

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

USAGE_AP_DELETE = """usage: phone-ap-delete [--yes] [--check]

Deletes the NetworkManager connection phonelink (the laptop AP) after
bringing it down if it is active. --check only reports; --yes skips the
confirmation. Needs root.
"""

USAGE_WIFI_CONNECT = """usage: phone-wifi-connect [SSID] [--password PASS] [--check]

Joins the network with WPA2 and waits until Android reports the association.
--check only reports whether the phone is connected to the SSID.
"""

USAGE_FIX_INTERNET = """usage: phone-fix-internet [--check] [--help]

Restores internet for the APK download/version check by trying mobile data,
USB tethering and the phone hotspot (the laptop joining as a client), checking
HTTPS after each step. --check only reports whether internet already works.
"""

USAGE_FIX_APK = """usage: phone-fix-apk [--refresh] [--releases [N]] [--check]

Caches this checkout's proxy APK (or PHONE_PROXY_APK) in the ambulance cache
(default /var/cache/phone-link) so a repair can reinstall the app when the tree
is not here: a build is a file, so keeping one is a copy.

--releases also keeps the APKs attached to the newest N releases of this
repository (5 when no number is given) — several versions to fall back on when
the app the phone needs is not the one this tree builds. Each is checked against
the .sha256 the release carries and named after its tag, so two releases of the
same app version do not overwrite each other. Old ones are dropped once the
kit holds more than three times N, oldest first, and the run says which.
--refresh does it too, since activation runs that; --check only lists what the
box holds.
"""


def _only_help(args: list[str], usage: str) -> None:
    for value in args:
        if value in ("-h", "--help"):
            print(usage, end="", file=sys.stderr)
            raise SystemExit(0)
        print(usage, end="", file=sys.stderr)
        die(f"unknown argument: {value}")


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


def _tool(name: str):
    """A sibling command: PATH first, then the checkout next to this package."""
    return actions.binary(actions.BY_ID[name])


def _root(argv: list[str]) -> None:
    """Run one command as root: directly when we are, else through sudo."""
    if phone.is_root():
        must(argv)
    else:
        must(["sudo", "--", *argv])


def phone_fix_forwarding(args: list[str]) -> int:
    """Turn on IPv4 forwarding, which AP mode and the tunnel need."""
    _only_help([value for value in args if value != "--check"], USAGE_FORWARDING)
    check_only = "--check" in args

    current = capture(["sysctl", "-n", "net.ipv4.ip_forward"])
    if check_only:
        log(f"ip_forward: {current or 'unknown'}")
        return 0 if current == "1" else 1
    if current == "1":
        log("IPv4 forwarding is already on")
        return 0

    log("enabling IPv4 forwarding")
    _root(["sysctl", "-w", "net.ipv4.ip_forward=1"])
    current = capture(["sysctl", "-n", "net.ipv4.ip_forward"])
    if current != "1":
        die(f"IPv4 forwarding is still {current or 'unknown'}")
    log("IPv4 forwarding is on (runtime only; set it in the NixOS config to persist)")
    return 0


def _route_present() -> bool:
    return any("2022" in line for line in capture(["ip", "rule", "show"]).splitlines())


def phone_fix_tunnel(args: list[str]) -> int:
    """Start or restart phone-tun and wait until its policy route is installed."""
    _only_help([value for value in args if value != "--check"], USAGE_TUNNEL)
    check_only = "--check" in args

    state = capture(["systemctl", "is-active", "phone-tun.service"])
    if check_only:
        log(
            f"phone-tun: {state or 'unknown'}, route: "
            f"{'present' if _route_present() else 'missing'}"
        )
        return 0 if state == "active" and _route_present() else 1
    if state == "active" and _route_present():
        log("phone-tun is already active with its route")
        return 0

    if state == "active":
        log("restarting phone-tun (route missing)")
        _root(["systemctl", "restart", "phone-tun.service"])
    else:
        log("starting phone-tun")
        _root(["systemctl", "start", "phone-tun.service"])

    for _ in range(10):
        if _route_present():
            log("phone-tun is active with its route")
            return 0
        time.sleep(1)
    die("phone-tun did not install its route")
    return 1


def phone_tunnel_run(args: list[str]) -> int:
    """Run the phone tunnel in the foreground from the config NixOS built."""
    phone.as_root("phone-tunnel-run", args)

    config = ""
    via_adb = False
    index = 0
    while index < len(args):
        value = args[index]
        if value == "--config":
            if index + 1 >= len(args):
                die("--config needs a value")
            config = args[index + 1]
            index += 2
            continue
        if value == "--via-adb":
            via_adb = True
        else:
            die(f"unknown argument: {value}")
        index += 1

    if not config:
        candidates = glob.glob("/nix/store/*-phone-tun.json")
        if candidates:
            config = max(candidates, key=os.path.getmtime)
        if not config:
            die("no built phone-tun.json; build the configuration first")

    sing_box = ""
    try:
        with open("/etc/systemd/system/phone-tun.service", encoding="utf-8") as unit:
            for line in unit:
                match = re.match(r"^ExecStart=(\S*sing-box) run", line)
                if match:
                    sing_box = match.group(1)
                    break
    except OSError:
        pass
    if not sing_box:
        import shutil

        sing_box = shutil.which("sing-box") or ""
    if not sing_box or not os.access(sing_box, os.X_OK):
        die("sing-box binary not found")

    with open(config, encoding="utf-8") as handle:
        text = handle.read()
    password = phone.read_secrets().get("PHONE_SOCKS_PASS", "")
    if not password:
        die(f"PHONE_SOCKS_PASS missing in {settings.PHONE_SECRETS}")

    # The store config carries the module's default port; the one in use can be
    # another (`phone-proxy-switch`), so it is filled in here the same way the
    # unit's ExecStartPre does.
    port = str(settings.active_port())
    rewritten = text.replace("@PHONE_SOCKS_PASS@", password).replace(
        "@PHONE_SOCKS_PORT@", port
    )
    # A config built before the placeholder existed still has a number.
    rewritten = re.sub(r'"server_port":\s*\d+', f'"server_port": {port}', rewritten)

    handle, temporary = tempfile.mkstemp(
        prefix="phone-tun.", suffix=".json", dir="/run"
    )
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as out:
            out.write(rewritten)
        os.chmod(temporary, 0o600)

        if via_adb:
            serial = phone.phone_serial()
            if not serial:
                die("no phone attached (see adb devices)")
            if status(
                ["adb", "-s", serial, "reverse", f"tcp:{port}", f"tcp:{port}"]
            ) != 0:
                die("adb reverse failed (is adb connected?)")
            with open(temporary, encoding="utf-8") as source:
                rewritten = source.read()
            rewritten = re.sub(
                r'"server": "[^"]*"', '"server": "127.0.0.1"', rewritten
            )
            with open(temporary, "w", encoding="utf-8") as out:
                out.write(rewritten)
            log(f"tunnel upstream: 127.0.0.1:{port} (adb reverse)")

        log(f"sing-box config: {temporary}")
        log("press Ctrl-C to stop; the TUN and its routes go away with it")
        os.execv(sing_box, [sing_box, "run", "-c", temporary])
    finally:
        try:
            os.unlink(temporary)
        except OSError:
            pass
    return 0


def phone_ap_up(args: list[str]) -> int:
    """Bring up the laptop access point the phone joins as a Wi-Fi client."""
    phone.as_root("phone-ap-up", args)

    if "* AP" not in capture(["iw", "list"]):
        die("driver reports no AP mode")
    if capture(["nmcli", "-g", "wifi.backend"]) == "iwd":
        die("NetworkManager uses iwd; AP mode needs wpa_supplicant")

    if not _profile_exists():
        if phone.ap_declarative():
            log(f"profile {settings.PHONE_AP_CON} missing; reloading it from phoneLink.ap")
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

    must(["nmcli", "connection", "up", settings.PHONE_AP_CON])
    must(["ip", "-4", "-br", "addr", "show", settings.PHONE_AP_IF])
    log("AP up. The phone must have Wi-Fi (client) on, not the hotspot.")
    return 0


def phone_ap_down(args: list[str]) -> int:
    """Stop the access point and go back to the phone's own hotspot."""
    phone.as_root("phone-ap-down", args)

    status(["nmcli", "connection", "down", settings.PHONE_AP_CON])
    if status(["nmcli", "connection", "up", settings.PHONE_HOTSPOT_CON]) != 0:
        log(
            f"could not join {settings.PHONE_HOTSPOT_CON} "
            "(is the phone sharing it?)"
        )
    must(["nmcli", "-t", "-f", "NAME,DEVICE", "con", "show", "--active"])
    return 0


def phone_ap_create(args: list[str]) -> int:
    """Create or refresh the laptop AP profile from the root-only secrets."""
    usage_args = [value for value in args if value not in ("--refresh", "--check")]
    _only_help(usage_args, USAGE_AP_CREATE)
    refresh = "--refresh" in args
    check_only = "--check" in args

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
                    f"PSK source: {settings.PHONE_SECRETS} not readable "
                    "(run with sudo)"
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
            f"{settings.PHONE_AP_CON} already exists "
            "(use --refresh to rewrite its PSK)"
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


def _remote_quote(value: str) -> str:
    """Single-quote a value for the remote sh, as the bash quote() did."""
    return "'" + value.replace("'", "'\\''") + "'"


def phone_wifi_connect(args: list[str]) -> int:
    """Connect the phone's Wi-Fi client to a network (default PhoneLink)."""
    ssid = settings.PHONE_AP_SSID
    password = ""
    check_only = False
    index = 0
    while index < len(args):
        value = args[index]
        if value == "--check":
            check_only = True
        elif value == "--password":
            if index + 1 >= len(args):
                die("--password needs a value")
            password = args[index + 1]
            index += 1
        elif value in ("-h", "--help"):
            print(USAGE_WIFI_CONNECT, end="", file=sys.stderr)
            return 0
        elif value.startswith("-"):
            print(USAGE_WIFI_CONNECT, end="", file=sys.stderr)
            die(f"unknown argument: {value}")
        else:
            ssid = value
        index += 1

    serial = phone.phone_serial()
    if not serial:
        die("no phone attached (see adb devices)")

    def phone_shell(*command: str) -> str:
        return capture(["adb", "-s", serial, "shell", *command]).replace("\r", "")

    def connected_ssid() -> str:
        for line in phone_shell("cmd", "wifi", "status").splitlines():
            match = re.match(r'Wifi is connected to "([^"]*)"', line)
            if match:
                return match.group(1)
        return ""

    current = connected_ssid()
    if check_only:
        if current == ssid:
            log(f"connected to {ssid}")
            return 0
        suffix = f" (connected to {current})" if current else ""
        log(f"not connected to {ssid}{suffix}")
        return 1
    if current == ssid:
        log(f"already connected to {ssid}")
        return 0

    if not any(
        line.startswith("Wifi is enabled")
        for line in phone_shell("cmd", "wifi", "status").splitlines()
    ):
        status(["adb", "-s", serial, "shell", "cmd", "wifi", "set-wifi-enabled", "enabled"])

    if not password:
        password = phone.ap_pass()

    log(f"connecting to {ssid}")
    # Single-quote for the remote sh, so spaces in the SSID and punctuation in
    # the passphrase survive adb's argument re-splitting.
    status(
        [
            "adb",
            "-s",
            serial,
            "shell",
            f"cmd wifi connect-network {_remote_quote(ssid)} wpa2 "
            f"{_remote_quote(password)}",
        ]
    )

    tries = int(os.environ.get("PHONE_WIFI_TRIES") or "20")
    poll = float(os.environ.get("PHONE_WIFI_POLL") or "1")
    for _ in range(tries):
        time.sleep(poll)
        if connected_ssid() == ssid:
            log(f"connected to {ssid}")
            return 0
    die(f"could not connect to {ssid} (wrong password or network not in range?)")
    return 1


def _online() -> bool:
    url = os.environ.get("PHONE_DOCTOR_URL") or "https://example.com"
    code = capture(
        [
            "curl",
            "-4",
            "-s",
            "-m",
            "10",
            "-o",
            "/dev/null",
            "-w",
            "%{http_code}",
            url,
        ],
        timeout=20,
    )
    return code == "200"


def _run_tool(name: str, *args: str) -> int:
    path = _tool(name)
    if not os.access(path, os.X_OK):
        log(f"warning: {name} not found")
        return 1
    return run([path, *args])


def phone_fix_internet(args: list[str]) -> int:
    """Restore internet by trying mobile data, USB tethering and the hotspot."""
    _only_help([value for value in args if value != "--check"], USAGE_FIX_INTERNET)
    check_only = "--check" in args

    if _online():
        log("internet is up")
        return 0
    if check_only:
        log("no internet")
        return 1

    log("no internet; trying mobile data")
    if _run_tool("phone-fix-mobile-data") != 0:
        log("warning: could not enable mobile data")
    time.sleep(3 * settings.PHONE_FIX_SETTLE)
    if _online():
        log("internet is up over mobile data")
        return 0

    log("trying USB tethering")
    serial = phone.phone_serial()
    if not serial:
        die("no phone attached (see adb devices)")
    status(["adb", "-s", serial, "shell", "svc", "usb", "setFunctions", "rndis,adb"])
    if _run_tool("phone-usb-tether-default") != 0:
        log("warning: could not set USB tethering")
    time.sleep(5 * settings.PHONE_FIX_SETTLE)
    if _online():
        log("internet is up over USB tethering")
        return 0

    log("trying the phone hotspot (laptop as a Wi-Fi client)")
    status(["adb", "-s", serial, "shell", "svc", "wifi", "disable"])
    status(
        [
            "adb",
            "-s",
            serial,
            "shell",
            f"cmd wifi start-softap {shlex.quote(settings.PHONE_HOTSPOT_SSID)}",
        ]
    )
    if settings.PHONE_HOTSPOT_CON in capture(
        ["nmcli", "-t", "-f", "NAME", "con", "show"]
    ).splitlines():
        if status(["nmcli", "connection", "up", settings.PHONE_HOTSPOT_CON]) != 0:
            log(f"warning: could not activate {settings.PHONE_HOTSPOT_CON}")
    elif os.environ.get("PHONE_HOTSPOT_PASS"):
        if (
            status(
                [
                    "nmcli",
                    "device",
                    "wifi",
                    "connect",
                    settings.PHONE_HOTSPOT_SSID,
                    "password",
                    os.environ["PHONE_HOTSPOT_PASS"],
                ]
            )
            != 0
        ):
            log(f"warning: could not join {settings.PHONE_HOTSPOT_SSID}")
    else:
        log(
            f"warning: no saved {settings.PHONE_HOTSPOT_CON} profile and "
            "no PHONE_HOTSPOT_PASS"
        )
    time.sleep(10 * settings.PHONE_FIX_SETTLE)
    if _online():
        log("internet is up over the phone hotspot")
        return 0

    die("could not restore internet; connect a working uplink and run phone-net-status")
    return 1


def _releases(limit: int) -> list[tuple[str, str]]:
    """(tag, APK URL) for the newest app releases, newest first."""
    api = (
        f"https://api.github.com/repos/{settings.PHONE_PROXY_REPO}"
        f"/releases?per_page={limit}"
    )
    code, body = run_text(["curl", "-fsSL", "--max-time", "30", api], timeout=40)
    if code != 0:
        return []
    found: list[tuple[str, str]] = []
    for match in re.finditer(
        r'"tag_name"\s*:\s*"([^"]+)"(.*?)(?="tag_name"|\Z)', body, re.S
    ):
        apk = re.search(r'"browser_download_url"\s*:\s*"([^"]+\.apk)"', match.group(2))
        if apk:
            found.append((match.group(1), apk.group(1)))
    return found[:limit]


def _stock_releases(limit: int) -> int:
    """Keep the newest releases' APKs in the box; returns how many are there.

    Every failure here is a warning: this is the repair kit for a host whose
    network may be the thing that is broken, and its absence must not stop the
    build that is already a file here from being kept.
    """
    releases = _releases(limit)
    if not releases:
        log(
            f"warning: cannot read the releases of {settings.PHONE_PROXY_REPO}; "
            "the box keeps what it has"
        )
        return 0
    kept = 0
    for tag, url in releases:
        name = f"{tag}-{url.rsplit('/', 1)[-1]}"
        target = os.path.join(settings.PHONE_APK_CACHE, name)
        if os.path.isfile(target) and os.path.getsize(target) > 0:
            log(f"kept: {name}")
            kept += 1
            continue
        part = f"{target}.part"
        code, _ = run_text(
            ["curl", "-fsSL", "--max-time", "300", "-o", part, url], timeout=330
        )
        if code != 0:
            log(f"warning: cannot download {tag} from {url}")
            continue
        expected = ""
        code, sums = run_text(
            ["curl", "-fsSL", "--max-time", "30", url + ".sha256"], timeout=40
        )
        if code == 0 and sums.strip():
            expected = sums.split()[0]
        with open(part, "rb") as handle:
            digest = hashlib.sha256(handle.read()).hexdigest()
        if expected and digest != expected:
            os.unlink(part)
            log(f"warning: {tag} does not match its checksum; not kept")
            continue
        os.replace(part, target)
        log(f"kept: {name} ({os.path.getsize(target)} bytes)")
        kept += 1
    return kept


def _prune_kit(limit: int) -> list[str]:
    """Drop old release APKs once the kit has grown past three times its size.

    The kit is for falling back a version or two; every release this host has
    ever seen is a museum, and `apk_cached()` picks by mtime, so the ones worth
    keeping are the ones just downloaded. Nothing is dropped while the box is
    small, and what went is named.
    """
    if limit <= 0:
        return []
    kit = sorted(
        (
            path
            for path in glob.glob(os.path.join(settings.PHONE_APK_CACHE, "*.apk"))
            if os.path.basename(path).startswith("v")
        ),
        key=os.path.getmtime,
        reverse=True,
    )
    if len(kit) <= 3 * limit:
        return []
    dropped: list[str] = []
    for path in kit[limit:]:
        try:
            os.unlink(path)
        except OSError:
            continue
        dropped.append(os.path.basename(path))
    return dropped


def phone_fix_apk(args: list[str]) -> int:
    """Stock the ambulance box with a proxy APK that works offline."""
    if any(value in ("-h", "--help") for value in args):
        print(USAGE_FIX_APK, end="", file=sys.stderr)
        return 0
    rest = [
        value for value in args if value not in ("--refresh", "--check", "--releases")
    ]
    if len(rest) > 1 or (rest and not rest[0].isdigit()):
        print(USAGE_FIX_APK, end="", file=sys.stderr)
        die(f"unknown argument: {rest[0]}")
    refresh = "--refresh" in args
    check_only = "--check" in args
    # --refresh is what activation runs, so the kit is refreshed with the build
    # rather than only when somebody remembers to ask for it.
    limit = int(rest[0]) if rest else (5 if ("--releases" in args or refresh) else 0)

    cached = phone.apk_cached()
    if check_only:
        boxed = sorted(glob.glob(os.path.join(settings.PHONE_APK_CACHE, "*.apk")))
        if not boxed:
            log(f"ambulance APK: none cached in {settings.PHONE_APK_CACHE}")
            return 1
        log(f"ambulance APKs: {len(boxed)} in {settings.PHONE_APK_CACHE}")
        for path in boxed:
            log(f"  {path}")
        return 0
    if not refresh and limit == 0 and cached:
        log(f"ambulance APK already stocked: {cached}")
        return 0

    # /var/cache is root-owned; a user run escalates once and redoes the work.
    try:
        os.makedirs(settings.PHONE_APK_CACHE, exist_ok=True)
    except OSError:
        if not phone.is_root():
            phone.as_root("phone-fix-apk", args)
        die(f"cannot create {settings.PHONE_APK_CACHE}")

    source = phone.app_apk()
    if source and not os.path.isfile(source):
        die(f"not a file: {source}")
    if source:
        target = os.path.join(settings.PHONE_APK_CACHE, os.path.basename(source))
        if os.path.abspath(source) == os.path.abspath(target):
            log(f"ambulance APK already stocked: {target}")
        else:
            log(f"copying {source} into {settings.PHONE_APK_CACHE}")
            shutil.copy2(source, target)
            log(f"ambulance APK ready: {target}")
    elif limit == 0:
        die(
            "no APK to cache: run phone-proxy-install --release once, "
            "or name one with PHONE_PROXY_APK"
        )

    if limit:
        kept = _stock_releases(limit)
        log(f"repair kit: {kept} release APK(s) in {settings.PHONE_APK_CACHE}")
        dropped = _prune_kit(limit)
        if dropped:
            log(f"dropped {len(dropped)} old release APK(s): {', '.join(dropped)}")
    return 0
