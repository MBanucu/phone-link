"""The read-only commands: the overview, net-check and the probes.

One function per bin/ script, printing the same lines the bash versions did so
the tests, the doctor and the GUI keep reading the same text. Nothing here
changes state, needs root or touches a secret the user cannot read.
"""

from __future__ import annotations

import re
import sys
import time
from pathlib import Path

from .. import phone, settings
from ..shell import capture, die, have, log

USAGE_NET_CHECK = """usage: net-check

Fetches https://example.com with curl, a Chrome/Chromium binary and
nix (builtins.fetchurl) and reports which of the three reach the internet.
"""

USAGE_TETHER_CHECK = """usage: phone-usb-tether-check

Checks that the phone exposes USB tethering (rndis0), that the host has a
route to it, and that https://example.com loads over that route.
"""

USAGE_CONCURRENCY = """usage: phone-wifi-concurrency

Reports whether Wi-Fi client mode (STA) and hotspot mode (AP) can run at the
same time. Read-only: nothing is enabled, disabled or tapped.
"""

CHROME_NAMES = (
    "google-chrome",
    "google-chrome-stable",
    "chromium",
    "chromium-browser",
)


def _only_help(args: list[str], usage: str) -> None:
    """--help exits 0; anything else prints the usage and dies, as before."""
    for value in args:
        if value in ("-h", "--help"):
            print(usage, end="", file=sys.stderr)
            raise SystemExit(0)
        print(usage, end="", file=sys.stderr)
        die(f"unknown argument: {value}")


def _field(number: int, text: str, index: int) -> str:
    fields = text.split()
    return fields[index] if len(fields) > index else ""


def phone_net_status(args: list[str]) -> int:
    """One-screen overview of the link: Wi-Fi, routes, proxy, adb, phone."""

    def say(label: str, value: str) -> None:
        print(f"{label:<20} {value}")

    active = capture(["nmcli", "-t", "-f", "NAME,DEVICE", "con", "show", "--active"])
    say(
        "wifi link",
        "\n".join(line for line in active.splitlines() if settings.PHONE_AP_IF in line)
        or "-",
    )
    say(
        "wifi address",
        _field(3, capture(["ip", "-4", "-br", "addr", "show", settings.PHONE_AP_IF]), 2),
    )
    say(
        "tether address",
        _field(3, capture(["ip", "-4", "-br", "addr", "show", "enp55s0u1"]), 2),
    )
    say("default route", capture(["ip", "route", "show", "default"]).replace("\n", " "))
    say("resolver", _resolver())
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
            "https://example.com",
        ],
        timeout=20,
    )
    say("internet", code or "000")

    connections = capture(["nmcli", "-t", "-f", "NAME,TYPE", "con", "show"])
    say(
        "ap profile",
        "".join(
            line + " "
            for line in connections.splitlines()
            if settings.PHONE_AP_CON in line
        ),
    )
    say("tunnel unit", capture(["systemctl", "is-active", "phone-tun.service"]))
    rules = capture(["ip", "rule", "show"]).splitlines()
    say("tunnel rules", str(sum(1 for line in rules if "2022" in line)))

    say("adb wireless", phone.adb_transport() or "none")
    say(
        "adb devices",
        "".join(
            f"{line.split()[0]} "
            for line in capture(["adb", "devices"]).splitlines()[1:]
            if len(line.split()) >= 2 and line.split()[1] == "device"
        ),
    )

    for address in (settings.PHONE_HOTSPOT_IP, settings.PHONE_AP_IP):
        say(f"proxy {address}", "open" if phone.tcp_open(address, 2) else "closed")

    serial = phone.phone_serial()
    if serial:
        say("phone serial", serial)
        say("phone addrs", "".join(f"{ip} " for ip in phone.phone_ips(serial)))
        say(
            "phone wifi",
            capture(
                [
                    "adb",
                    "-s",
                    serial,
                    "shell",
                    'cmd wifi status 2>/dev/null | head -2 | tr "\n" " "',
                ]
            ).replace("\r", ""),
        )
        say(
            "wireless dbg",
            capture(
                [
                    "adb",
                    "-s",
                    serial,
                    "shell",
                    "settings get global adb_wifi_enabled; "
                    "getprop service.adb.tcp.port",
                ]
            )
            .replace("\r", "")
            .replace("\n", " "),
        )
    return 0


def _resolver() -> str:
    """resolv.conf without its comments, on one line, as an overview value."""
    try:
        lines = Path("/etc/resolv.conf").read_text(encoding="utf-8").splitlines()
    except OSError:
        return ""
    return "".join(f"{line} " for line in lines if not line.startswith("#"))


def net_check(args: list[str]) -> int:
    """Fetch a fresh URL with curl, Chrome and Nix, then report the verdict."""
    _only_help(args, USAGE_NET_CHECK)

    failed = False
    url = f"https://example.com/?net-check={int(time.time())}"

    if have("curl"):
        code = capture(
            [
                "curl",
                "-4",
                "-s",
                "-m",
                "20",
                "-o",
                "/dev/null",
                "-w",
                "%{http_code}",
                url,
            ],
            timeout=30,
        )
        if code == "200":
            log(f"curl:    {url} = 200")
        else:
            log(f"curl:    {url} = {code or '000'}")
            failed = True
    else:
        log("curl:    not installed")
        failed = True

    chrome = next((name for name in CHROME_NAMES if have(name)), None)
    if chrome:
        dom = capture(
            [
                chrome,
                "--headless",
                "--disable-gpu",
                "--no-sandbox",
                "--disable-dev-shm-usage",
                "--dump-dom",
                url,
            ],
            timeout=90,
        )
        if "Example Domain" in dom:
            log(f"chrome:  {chrome} loaded {url}")
        else:
            log(f"chrome:  {chrome} could not load {url}")
            failed = True
    else:
        log(
            "chrome:  no google-chrome, google-chrome-stable, chromium or "
            "chromium-browser found"
        )
        failed = True

    if have("nix"):
        html = capture(
            [
                "nix",
                "eval",
                "--raw",
                "--impure",
                "--expr",
                f'builtins.readFile (builtins.fetchurl "{url}")',
            ],
            timeout=120,
        )
        if "Example Domain" in html:
            log(f"nix:     builtins.fetchurl loaded {url}")
        else:
            log(f"nix:     builtins.fetchurl could not load {url}")
            failed = True
    else:
        log("nix:     not installed")
        failed = True

    if not failed:
        log("verdict: the internet is reachable with curl, chrome and nix")
        return 0
    log("verdict: at least one way of reaching the internet failed")
    return 1


def phone_proxy_check(args: list[str]) -> int:
    """Probe the proxy on the hotspot and AP addresses; 0 if either answers."""
    reachable = False
    for address in (settings.PHONE_HOTSPOT_IP, settings.PHONE_AP_IP):
        if phone.proxy_check(address):
            reachable = True
    return 0 if reachable else 1


def phone_usb_tether_check(args: list[str]) -> int:
    """Report whether USB tethering is active and reaches the internet."""
    _only_help(args, USAGE_TETHER_CHECK)

    serial = phone.phone_serial() or die("no phone attached (see adb devices)")

    def phone_shell(*command: str) -> str:
        return capture(["adb", "-s", serial, "shell", *command]).replace("\r", "")

    phone_ip = _rndis_address(phone_shell("ip", "-4", "-o", "addr", "show", "rndis0"))
    usb_config = (phone_shell("getprop", "sys.usb.config").splitlines() or [""])[0]
    tethering = phone_shell("dumpsys", "tethering")
    tether_state = next(
        (
            match.group(1)
            for match in (
                re.match(r" *rndis0 - ([^ ]*)", line)
                for line in tethering.splitlines()
            )
            if match
        ),
        "",
    )

    if not phone_ip:
        log("phone:    USB tethering is not active (rndis0 has no IPv4 address)")
        log("verdict:  USB tethering is off")
        return 1
    if tether_state != "TetheredState" and "rndis" not in usb_config.lower():
        log(
            f"phone:    rndis0 is {phone_ip} but USB tethering is not enabled "
            f"(usb={usb_config}, tether={tether_state or 'unknown'})"
        )
        log("verdict:  USB tethering is off")
        return 1
    log(
        f"phone:    USB tethering active: rndis0 {phone_ip}/24 "
        f"(usb={usb_config}, tether={tether_state or 'unknown'})"
    )

    route = capture(["ip", "-o", "route", "get", phone_ip]).splitlines()[0:1]
    line = route[0] if route else ""
    interface = re.search(r" dev ([^ ]+)", line)
    source = re.search(r" src ([^ ]+)", line)
    if not interface or not source:
        log(f"host:     no route to {phone_ip}")
        log("verdict:  the phone tethers, but this host has no USB tether route")
        return 1
    log(
        f"host:     {interface.group(1)} with {source.group(1)}, "
        f"route via {phone_ip}"
    )

    code = capture(
        [
            "curl",
            "-4",
            "-s",
            "-m",
            "20",
            "--interface",
            source.group(1),
            "-o",
            "/dev/null",
            "-w",
            "%{http_code}",
            "https://example.com",
        ],
        timeout=30,
    )
    log(f"internet: https://example.com over {source.group(1)} = {code or '000'}")
    if code == "200":
        log("verdict:  USB tethering is active and reaches the internet")
        return 0
    log(f"verdict:  USB tethering is up, but no internet over it (HTTP {code or '000'})")
    return 1


def _rndis_address(output: str) -> str:
    for line in output.splitlines():
        fields = line.split()
        if len(fields) >= 4 and fields[1] == "rndis0":
            return fields[3].split("/")[0]
    return ""


def phone_wifi_concurrency(args: list[str]) -> int:
    """Report whether the phone can run a Wi-Fi client and hotspot at once."""
    _only_help(args, USAGE_CONCURRENCY)

    serial = phone.phone_serial() or die("no phone attached (see adb devices)")

    def phone_shell(*command: str) -> str:
        return capture(["adb", "-s", serial, "shell", *command]).replace("\r", "")

    wifi = phone_shell("dumpsys", "wifi")
    if not wifi:
        die("could not read dumpsys wifi (is the phone authorised for adb?)")
    status = phone_shell("cmd", "wifi", "status")
    addresses = phone_shell("ip", "-4", "-o", "addr", "show")

    def prop(name: str) -> str:
        values = phone_shell("getprop", name).splitlines()
        return values[0] if values else ""

    model = prop("ro.product.model")
    release = prop("ro.build.version.release")
    sdk = prop("ro.build.version.sdk")

    lines = wifi.splitlines()
    sta_ap = _supported(lines, "STA + AP Concurrency Supported")
    sta_sta = _supported(lines, "STA + STA Concurrency Supported")
    features = next(
        (
            line.partition("SupportedFeatures: [")[2].rsplit("]", 1)[0].replace(" ", "")
            for line in lines
            if "SupportedFeatures: [" in line
        ),
        "",
    )
    has_ap_sta = "WIFI_FEATURE_AP_STA" in features.split(",")
    has_dual_band = "WIFI_FEATURE_DUAL_BAND_SIMULTANEOUS" in features.split(",")

    client_managers = _last_number(lines, "num ClientModeManagers:")
    softap_managers = _last_number(lines, "num SoftApManagers:")
    ap_ip = _interface_address(addresses, "ap")
    wlan_ip = _interface_address(addresses, "wlan")

    wifi_state = "unknown"
    if any(line.startswith("Wifi is enabled") for line in status.splitlines()):
        wifi_state = "enabled"
    elif any(line.startswith("Wifi is disabled") for line in status.splitlines()):
        wifi_state = "disabled"
    ssid = next(
        (
            match.group(1)
            for match in (
                re.match(r'Wifi is connected to "([^"]*)"', line)
                for line in status.splitlines()
            )
            if match
        ),
        "",
    )
    if ssid:
        wifi_state = f'{wifi_state}, connected to "{ssid}"'
    elif any(line.startswith("Wifi is not connected") for line in status.splitlines()):
        wifi_state = f"{wifi_state}, not connected"
    ap_state = f"active on ap0 ({ap_ip})" if ap_ip else "not active"

    log(f"phone:     {model or 'unknown'} (Android {release or '?'}, sdk {sdk or '?'})")
    log(
        "framework: STA + AP concurrency = "
        f"{sta_ap or 'unknown'}"
        + (f" (STA + STA = {sta_sta})" if sta_sta else "")
    )
    log(
        f"driver:    AP_STA feature = {str(has_ap_sta).lower()}, "
        f"simultaneous dual band = {str(has_dual_band).lower()}"
    )
    current = f"current:   Wi-Fi {wifi_state}; hotspot {ap_state}"
    if client_managers is not None:
        current += (
            f"; managers client={client_managers} softap={softap_managers or '0'}"
        )
    if wlan_ip:
        current += f"; wlan0 {wlan_ip}"
    log(current)

    if sta_ap == "true":
        log("verdict:   Wi-Fi client and hotspot can run at the same time")
        return 0
    if sta_ap == "false":
        log("verdict:   Wi-Fi client and hotspot cannot run at the same time")
        return 1

    # No framework line (older builds): fall back to the driver feature and
    # what the managers are doing right now.
    if (
        has_ap_sta
        and (client_managers or 0) >= 1
        and (softap_managers or 0) >= 1
    ):
        log(
            "verdict:   both managers are up, so concurrency is working "
            "despite no framework line"
        )
        return 0
    if has_ap_sta:
        log(
            "verdict:   the driver advertises STA+AP but the framework does "
            "not report support"
        )
        return 2
    log("verdict:   no STA+AP concurrency support found")
    return 1


def _supported(lines: list[str], label: str) -> str:
    pattern = re.compile(re.escape(label) + r": (true|false)$")
    for line in lines:
        match = pattern.match(line)
        if match:
            return match.group(1)
    return ""


def _last_number(lines: list[str], label: str) -> int | None:
    found: int | None = None
    pattern = re.compile(re.escape(label) + r"([0-9]+)")
    for line in lines:
        for match in pattern.finditer(line):
            found = int(match.group(1))
    return found


def _interface_address(output: str, prefix: str) -> str:
    for line in output.splitlines():
        fields = line.split()
        if len(fields) >= 4 and fields[1].startswith(prefix):
            return fields[3].split("/")[0]
    return ""
