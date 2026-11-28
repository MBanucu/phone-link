"""USB tethering: make the RNDIS gadget the default USB action.

This changes only the phone and needs no root. Changing the USB functions
re-enumerates the gadget, so every setting is read back.
"""

from __future__ import annotations

import re
import time

from .. import settings
from ..shell import die, log, status
from .common import _first_line, _only_help, _serial, _shell


USAGE_TETHER_DEFAULT = """usage: phone-usb-tether-default [--check]

Makes USB tethering (RNDIS) the default USB action while keeping adb. --check
only reports whether it is already the default.
"""


def phone_usb_tether_default(args: list[str]) -> int:
    """Make USB tethering the default USB action while keeping adb."""
    _only_help([value for value in args if value != "--check"], USAGE_TETHER_DEFAULT)
    check_only = "--check" in args
    serial = _serial()

    def read_state() -> tuple[str, str]:
        config = _first_line(_shell(serial, "getprop", "sys.usb.config"))
        unlocked = ""
        for line in _shell(serial, "dumpsys", "usb").splitlines():
            match = re.search(r"screen_unlocked_functions=(.*)$", line)
            if match:
                unlocked = match.group(1)
                break
        return config, unlocked

    def is_rndis(value: str) -> bool:
        return "rndis" in value.lower()

    config, unlocked = read_state()
    current = is_rndis(config)
    default = is_rndis(unlocked)

    if check_only:
        log(
            f"current:  {config or 'unknown'} (USB tethering {'active' if current else 'no'})"
        )
        log(
            f"default:  {unlocked or 'unknown'} (tether on unlock {'enabled' if default else 'no'})"
        )
        if current and default:
            log("verdict:  USB tethering is the default USB action")
            return 0
        log("verdict:  USB tethering is not the default USB action")
        return 1

    if not current:
        log("setting current USB functions to rndis,adb")
        status(
            ["adb", "-s", serial, "shell", "svc", "usb", "setFunctions", "rndis,adb"]
        )
    if not default:
        log("setting screen-unlocked USB functions to rndis,adb")
        status(
            [
                "adb",
                "-s",
                serial,
                "shell",
                "svc",
                "usb",
                "setScreenUnlockedFunctions",
                "rndis,adb",
            ]
        )

    # Changing functions makes the adb client abort while the gadget
    # re-enumerates, so a setter can be lost. Re-read and re-issue only what is
    # still missing.
    tries = 0
    while True:
        config, unlocked = read_state()
        current = is_rndis(config)
        default = is_rndis(unlocked)
        if current and default:
            break
        if tries >= settings.PHONE_TETHER_TRIES:
            break
        if not current:
            status(
                [
                    "adb",
                    "-s",
                    serial,
                    "shell",
                    "svc",
                    "usb",
                    "setFunctions",
                    "rndis,adb",
                ]
            )
        if not default:
            status(
                [
                    "adb",
                    "-s",
                    serial,
                    "shell",
                    "svc",
                    "usb",
                    "setScreenUnlockedFunctions",
                    "rndis,adb",
                ]
            )
        tries += 1
        time.sleep(1)

    if not is_rndis(config):
        die(f"USB tethering did not become current (sys.usb.config={config})")
    if not is_rndis(unlocked):
        die(
            "USB tethering did not become the default "
            f"(screen_unlocked_functions={unlocked})"
        )
    log(
        f"USB tethering is now the default USB action "
        f"(current {config}, on unlock {unlocked})"
    )
    return 0
