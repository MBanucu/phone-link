"""The privileged network commands: forwarding, tunnel, AP and Wi-Fi link.

These are the actions the GUI marks with a lock. Each one escalates through
sudo only when it has to, exactly as the bash versions did: `phone-ap-up` and
`phone-tunnel-run` re-run themselves as root up front, while the forwarding and
tunnel repairs wrap just the `sysctl`/`systemctl` call.
"""

from __future__ import annotations

import glob
import os
import re
import secrets as random_secrets
import sys
import tempfile
import time

from .. import actions, phone, settings
from ..shell import capture, die, log, must, run, status

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
PHONE_AP_ADDRESS. The PSK stays out of the Nix store. --refresh rewrites an
existing profile, e.g. after rotating the password; --check only reports.

When phoneLink.ap declares the profile, --refresh restarts the
NetworkManager-ensure-profiles unit instead of editing NetworkManager.
"""

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

USAGE_FIX_APK = """usage: phone-fix-apk [--refresh] [--check]

Caches the proxy APK in the ambulance cache (default /var/cache/phone-link) so
phone-doctor-fix can reinstall the app without a download. --refresh replaces
the cache with F-Droid's current suggested version; --check only reports.
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

    handle, temporary = tempfile.mkstemp(
        prefix="phone-tun.", suffix=".json", dir="/run"
    )
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as out:
            out.write(text.replace("@PHONE_SOCKS_PASS@", password))
        os.chmod(temporary, 0o600)

        if via_adb:
            port = str(settings.PHONE_PROXY_PORT)
            if status(["adb", "reverse", f"tcp:{port}", f"tcp:{port}"]) != 0:
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
    if capture(["sysctl", "-n", "net.ipv4.ip_forward"]) != "1":
        die("net.ipv4.ip_forward is 0")

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
        log(
            f"{settings.PHONE_AP_CON} exists"
            if _profile_exists()
            else f"{settings.PHONE_AP_CON} is missing"
        )
        if phone.ap_declarative():
            log(f"{settings.PHONE_AP_CON} is declared by phoneLink.ap")
            log(
                f"PSK source: {settings.PHONE_SECRETS} "
                f"(read by {settings.PHONE_AP_ENSURE_UNIT} as root)"
            )
        elif os.access(settings.PHONE_SECRETS, os.R_OK):
            log(f"PSK source: {settings.PHONE_SECRETS} (PHONE_AP_PASS)")
        else:
            log(f"PSK source: {settings.PHONE_SECRETS} not readable (run with sudo)")
        return 0 if _profile_exists() else 1

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

    if _profile_exists() and not refresh:
        log(
            f"{settings.PHONE_AP_CON} already exists "
            "(use --refresh to rewrite its PSK)"
        )
        return 0

    phone.as_root("phone-ap-create", args)
    password = phone.ap_pass()

    base = [
        "ssid",
        settings.PHONE_AP_SSID,
        "802-11-wireless.mode",
        "ap",
        "802-11-wireless.band",
        "bg",
        "802-11-wireless.channel",
        "1",
        "wifi-sec.key-mgmt",
        "wpa-psk",
        "wifi-sec.psk",
        password,
        "ipv4.method",
        "shared",
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
    time.sleep(3)
    if _online():
        log("internet is up over mobile data")
        return 0

    log("trying USB tethering")
    status(["adb", "shell", "svc", "usb", "setFunctions", "rndis,adb"])
    if _run_tool("phone-usb-tether-default") != 0:
        log("warning: could not set USB tethering")
    time.sleep(5)
    if _online():
        log("internet is up over USB tethering")
        return 0

    log("trying the phone hotspot (laptop as a Wi-Fi client)")
    status(["adb", "shell", "svc", "wifi", "disable"])
    status(["adb", "shell", "cmd", "wifi", "start-softap", settings.PHONE_HOTSPOT_SSID])
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
    time.sleep(10)
    if _online():
        log("internet is up over the phone hotspot")
        return 0

    die("could not restore internet; connect a working uplink and run phone-net-status")
    return 1


def phone_fix_apk(args: list[str]) -> int:
    """Stock the ambulance box with a proxy APK that works offline."""
    _only_help(
        [value for value in args if value not in ("--refresh", "--check")],
        USAGE_FIX_APK,
    )
    refresh = "--refresh" in args
    check_only = "--check" in args

    cached = phone.apk_cached()
    if check_only:
        if cached:
            log(f"ambulance APK: {cached}")
            return 0
        log(f"ambulance APK: none cached in {settings.PHONE_APK_CACHE}")
        return 1
    if not refresh and cached:
        log(f"ambulance APK already stocked: {cached}")
        return 0

    # /var/cache is root-owned; a user run escalates once and redoes the work.
    try:
        os.makedirs(settings.PHONE_APK_CACHE, exist_ok=True)
    except OSError:
        if not phone.is_root():
            phone.as_root("phone-fix-apk", args)
        die(f"cannot create {settings.PHONE_APK_CACHE}")

    installer = _tool("phone-proxy-install")
    if not os.access(installer, os.X_OK):
        die("phone-proxy-install not found")

    log(f"downloading the proxy APK into {settings.PHONE_APK_CACHE}")
    environment = dict(os.environ, PHONE_APK_DIR=settings.PHONE_APK_CACHE)
    import subprocess

    try:
        done = subprocess.run([installer, "--fdroid", "--check"], env=environment)
    except OSError:
        die("phone-proxy-install could not be started")
    if done.returncode != 0:
        raise SystemExit(done.returncode)

    cached = phone.apk_cached()
    if not cached:
        die(f"no APK appeared in {settings.PHONE_APK_CACHE}")
    log(f"ambulance APK ready: {cached}")
    return 0
