"""The adb-over-Wi-Fi commands: the legacy TCP listener and TLS debugging.

Enabling either one changes only the phone and needs no root, but the legacy
`adb tcpip` restarts adbd and blips USB adb and the tether.
"""

from __future__ import annotations

import re
import sys
import time

from .. import phone, settings
from ..shell import capture, die, have, log, status
from .common import _first_line, _serial, _shell


USAGE_ADB_WIFI = """usage: phone-adb-wifi [--legacy | --tls] [--check]

Enables adb over Wi-Fi: the legacy `adb tcpip 5555` listener and Android 11+
wireless debugging on its random TLS port, then connects to both. --legacy or
--tls picks one; --check only reports the current state.
"""


def _print_devices() -> None:
    devices = capture(["adb", "devices"])
    if devices:
        print(devices)


def phone_adb_wifi(args: list[str]) -> int:
    """Enable adb over Wi-Fi: the legacy TCP port and wireless debugging."""
    legacy = tls = False
    mode_given = False
    check_only = False
    for value in args:
        if value == "--legacy":
            if not mode_given:
                legacy = tls = False
                mode_given = True
            legacy = True
        elif value == "--tls":
            if not mode_given:
                legacy = tls = False
                mode_given = True
            tls = True
        elif value == "--check":
            check_only = True
        elif value in ("-h", "--help"):
            print(USAGE_ADB_WIFI, end="", file=sys.stderr)
            return 0
        else:
            print(USAGE_ADB_WIFI, end="", file=sys.stderr)
            die(f"unknown argument: {value}")
    if not mode_given:
        legacy = tls = True

    serial = _serial()
    if not have("avahi-browse"):
        log("warning: avahi-browse is missing, cannot read the wireless debugging port")

    def wifi_debugging() -> str:
        return _first_line(
            _shell(serial, "settings", "get", "global", "adb_wifi_enabled")
        )

    def legacy_port() -> str:
        return _first_line(_shell(serial, "getprop", "service.adb.tcp.port"))

    def tls_endpoint() -> str | None:
        # The TLS port is random and not exported as a property; adbd
        # advertises it over mDNS as adb-<serial>-<random>.
        if not have("avahi-browse"):
            return None
        output = capture(["avahi-browse", "-rt", "_adb-tls-connect._tcp"], timeout=15)
        seen = False
        address = ""
        port = ""
        for line in output.splitlines():
            if line.startswith("=") and "IPv4" in line and f"adb-{serial}" in line:
                seen = True
                continue
            if not seen:
                continue
            match = re.search(r"address = \[([^\]]*)\]", line)
            if match:
                address = match.group(1)
            match = re.search(r"port = \[([^\]]*)\]", line)
            if match:
                port = match.group(1)
            if address and port:
                return f"{address}:{port}"
        return None

    if check_only:
        log(f"wireless debugging: {wifi_debugging() or 'unknown'}")
        log(f"legacy tcp port:  {legacy_port() or 'not set'}")
        endpoint = tls_endpoint()
        log(f"tls endpoint:     {endpoint or 'not advertised'}")
        _print_devices()
        return 0

    addresses = phone.phone_ips(serial)

    if tls:
        if wifi_debugging() == "1":
            log("wireless debugging already enabled")
        else:
            status(
                [
                    "adb",
                    "-s",
                    serial,
                    "shell",
                    "settings",
                    "put",
                    "global",
                    "adb_wifi_enabled",
                    "1",
                ]
            )
            log("enabled wireless debugging (random TLS port)")

    if legacy:
        if legacy_port() == settings.PHONE_ADB_PORT:
            log(f"legacy adbd already on {settings.PHONE_ADB_PORT}")
        else:
            log(
                f"warning: adb tcpip {settings.PHONE_ADB_PORT} restarts adbd "
                "(USB adb and the tether blip)"
            )
            if status(["adb", "-s", serial, "tcpip", settings.PHONE_ADB_PORT]) != 0:
                die("adb tcpip failed")
            time.sleep(settings.PHONE_ADB_POLL)

        connected = False
        candidates = list(
            dict.fromkeys(
                [
                    address
                    for address in [
                        *addresses,
                        settings.PHONE_HOTSPOT_IP,
                        settings.PHONE_AP_IP,
                    ]
                    if address
                ]
            )
        )
        for address in candidates:
            target = f"{address}:{settings.PHONE_ADB_PORT}"
            if status(["adb", "connect", target], timeout=20) != 0:
                continue
            if capture(["adb", "-s", target, "get-state"]) == "device":
                log(f"legacy adb on {target}")
                connected = True
                break
        if not connected:
            die(f"no phone address answered on {settings.PHONE_ADB_PORT}")

    if tls:
        # adbd may still advertise the old port for a moment after a restart,
        # so reconnect until one of the advertised endpoints really accepts
        # adb.
        reachable = False
        for _ in range(8):
            endpoint = tls_endpoint()
            if endpoint:
                status(["adb", "connect", endpoint], timeout=20)
                if capture(["adb", "-s", endpoint, "get-state"]) == "device":
                    log(f"wireless debugging on {endpoint}")
                    reachable = True
                    break
            time.sleep(settings.PHONE_ADB_POLL)
        if not reachable:
            if not legacy:
                die("wireless debugging did not become reachable")
            log("warning: wireless debugging is on but no TLS port accepted adb")

    _print_devices()
    return 0


def adb_wifi_connect(args: list[str]) -> int:
    """Connect adb to the phone over TCP."""
    if args and args[0] == "--prepare":
        log("warning: adb tcpip resets the USB gadget (the tether will blip)")
        serial = _serial()
        if status(["adb", "-s", serial, "tcpip", settings.PHONE_ADB_PORT]) != 0:
            die("adb tcpip failed (cable attached?)")
        time.sleep(settings.PHONE_ADB_POLL)

    target = ""
    for address in [
        *phone.phone_ips(),
        settings.PHONE_HOTSPOT_IP,
        settings.PHONE_AP_IP,
    ]:
        if phone.tcp_open(address, 2, int(settings.PHONE_ADB_PORT)):
            target = address
            break
    if not target:
        die("no adb TCP listener reachable on the phone")

    if status(["adb", "connect", f"{target}:{settings.PHONE_ADB_PORT}"]) != 0:
        die("adb connect failed")
    _print_devices()
    transport = phone.adb_transport()
    if transport:
        log(f"adb over Wi-Fi: {transport}")
    return 0
