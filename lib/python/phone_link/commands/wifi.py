"""The phone's Wi-Fi client: enable the radio, forget, connect and reconnect.

These change only the phone and need no root. The serial is always named, so a
USB and a Wi-Fi transport can be attached at once.
"""

from __future__ import annotations

import os
import re
import sys
import time

from .. import phone, settings
from ..shell import capture, die, log, status
from .common import _only_help, _serial, _shell


USAGE_WIFI_ENABLE = """usage: phone-wifi-enable [--check]

Turns Wi-Fi on and waits until Android reports it enabled. --check reports
without changing anything.
"""

USAGE_WIFI_FORGET = """usage: phone-wifi-forget [SSID] [--check] [--yes]

Removes the saved network, so a later connect starts from clean credentials.
--check only reports whether the SSID is saved. --yes skips the prompt.
"""

USAGE_WIFI_CONNECT = """usage: phone-wifi-connect [SSID] [--password PASS] [--check]

Joins the network with WPA2 and waits until Android reports the association.
--check only reports whether the phone is connected to the SSID.
"""

USAGE_WIFI_RECONNECT = """usage: phone-wifi-reconnect [--check]

Applies the two Android globals this phone needs to rejoin after a long AP
outage: network_avoid_bad_wifi=0 and wifi_always_requested=1. Without --check
both are written and read back; --check only reports them and exits 0 when
both already match. Nothing is changed by the doctor or any other command.
"""


def _remote_quote(value: str) -> str:
    """Single-quote a value for the remote sh, as the bash quote() did."""
    return "'" + value.replace("'", "'\\''") + "'"


def phone_wifi_enable(args: list[str]) -> int:
    """Enable the phone's Wi-Fi radio, or report its state."""
    _only_help([value for value in args if value != "--check"], USAGE_WIFI_ENABLE)
    check_only = "--check" in args
    serial = _serial()

    def wifi_enabled() -> bool:
        lines = _shell(serial, "cmd", "wifi", "status").splitlines()
        return any(line.startswith("Wifi is enabled") for line in lines)

    if wifi_enabled():
        log("Wi-Fi is enabled")
        return 0
    if check_only:
        log("Wi-Fi is disabled")
        return 1

    status(["adb", "-s", serial, "shell", "cmd", "wifi", "set-wifi-enabled", "enabled"])
    for _ in range(settings.PHONE_WIFI_TRIES):
        time.sleep(settings.PHONE_WIFI_POLL)
        if wifi_enabled():
            log("Wi-Fi enabled")
            return 0
    die("Wi-Fi did not come up")
    return 1


def phone_wifi_forget(args: list[str]) -> int:
    """Forget a saved Wi-Fi network on the phone (default PhoneLink)."""
    ssid = settings.PHONE_AP_SSID
    check_only = False
    assume_yes = False
    for value in args:
        if value == "--check":
            check_only = True
        elif value == "--yes":
            assume_yes = True
        elif value in ("-h", "--help"):
            print(USAGE_WIFI_FORGET, end="", file=sys.stderr)
            return 0
        elif value.startswith("-"):
            print(USAGE_WIFI_FORGET, end="", file=sys.stderr)
            die(f"unknown argument: {value}")
        else:
            ssid = value

    serial = _serial()

    def network_id() -> str:
        # The list is "id   SSID   security"; the SSID may contain spaces, so
        # split on runs of two or more spaces.
        for line in _shell(serial, "cmd", "wifi", "list-networks").splitlines():
            parts = re.split(r"\s{2,}", line.strip())
            if len(parts) >= 3 and parts[1] == ssid:
                return parts[0]
        return ""

    network = network_id()
    if not network:
        log(f"{ssid} is not saved")
        return 0
    if check_only:
        log(f"{ssid} is saved (network id {network})")
        return 1

    if not assume_yes:
        sys.stderr.write(f"Forget {ssid} on the phone? [y/N] ")
        sys.stderr.flush()
        try:
            with open("/dev/tty", encoding="utf-8") as tty:
                answer = tty.readline().strip()
        except OSError:
            answer = ""
        if answer not in ("y", "Y", "yes", "YES"):
            die("aborted")

    log(f"forgetting {ssid} (network id {network})")
    status(["adb", "-s", serial, "shell", "cmd", "wifi", "forget-network", network])
    if network_id():
        die(f"{ssid} is still saved")
    log(f"{ssid} forgotten")
    return 0


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
        status(
            ["adb", "-s", serial, "shell", "cmd", "wifi", "set-wifi-enabled", "enabled"]
        )

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


def phone_wifi_reconnect(args: list[str]) -> int:
    """Apply or report the Android globals that make long outages recover."""
    check_only = False
    for value in args:
        if value == "--check":
            check_only = True
        elif value in ("-h", "--help"):
            print(USAGE_WIFI_RECONNECT, end="", file=sys.stderr)
            return 0
        else:
            print(USAGE_WIFI_RECONNECT, end="", file=sys.stderr)
            die(f"unknown argument: {value}")

    serial = phone.phone_serial()
    if not serial:
        die("no phone attached (see adb devices)")

    def current(name: str) -> str:
        return capture(
            ["adb", "-s", serial, "shell", "settings", "get", "global", name]
        ).strip()

    if not check_only:
        for name, wanted in phone.WIFI_RECONNECT_GLOBALS:
            log(f"setting {name}={wanted}")
            status(
                [
                    "adb",
                    "-s",
                    serial,
                    "shell",
                    "settings",
                    "put",
                    "global",
                    name,
                    wanted,
                ]
            )

    values = {name: current(name) for name, _ in phone.WIFI_RECONNECT_GLOBALS}
    mismatched = []
    for name, wanted in phone.WIFI_RECONNECT_GLOBALS:
        value = values[name] or "unset"
        if values[name] == wanted:
            log(f"{name}: {value} (recommended)")
        else:
            log(f"{name}: {value} (want {wanted})")
            mismatched.append(name)

    if mismatched:
        if check_only:
            log("not applied (run phone-wifi-reconnect to set both)")
        else:
            die(
                "could not set "
                + ", ".join(mismatched)
                + " (does the phone accept settings put global?)"
            )
        return 1
    log(
        "Wi-Fi reconnect globals match" if check_only else "Wi-Fi reconnect globals set"
    )
    return 0
