"""Unlock, reboot and USB-tether cycle: the screen-driven phone commands.

These read PHONE_PIN from the environment or the root-only secrets file, so
they escalate on their own when started unprivileged.
"""

from __future__ import annotations

import os
import re
import sys
import time

from .. import phone, settings, ui
from ..shell import capture, die, log, must, run, status

USAGE_UNLOCK = """usage: phone-unlock [--check]

Unlocks the phone with PHONE_PIN (environment) or PHONE_PIN from the secrets
file. --check only reports whether the keyguard is showing.
"""

USAGE_REBOOT = """usage: phone-reboot-unlock [--yes]

Reboots the phone, waits for Android to finish booting and then runs
phone-unlock once. --yes skips the confirmation prompt.
"""

USAGE_CYCLE = """usage: phone-tether-cycle [--yes]

Switches USB to MTP so RNDIS is off while adb stays up, runs net-check, then
locks and unlocks the phone to apply the screen-unlocked rndis,adb functions
again and verifies the tether with phone-usb-tether-check. --yes skips the
prompt.
"""


def _only_help(args: list[str], usage: str) -> None:
    for value in args:
        if value in ("-h", "--help"):
            print(usage, end="", file=sys.stderr)
            raise SystemExit(0)
        print(usage, end="", file=sys.stderr)
        die(f"unknown argument: {value}")


def _confirm_tty(prompt: str) -> bool:
    """Ask on /dev/tty, as the bash scripts did; no tty means no."""
    sys.stderr.write(prompt)
    sys.stderr.flush()
    try:
        with open("/dev/tty", encoding="utf-8") as tty:
            return tty.readline().strip() in ("y", "Y", "yes", "YES")
    except OSError:
        return False


def _phone_shell(serial: str, *command: str) -> str:
    return capture(["adb", "-s", serial, "shell", *command]).replace("\r", "")


def _pin() -> str:
    pin = os.environ.get("PHONE_PIN", "")
    if not pin:
        if not os.access(settings.PHONE_SECRETS, os.R_OK):
            die(
                f"PHONE_PIN is unset and {settings.PHONE_SECRETS} is not readable "
                "(export PHONE_PIN or run with sudo)"
            )
        pin = phone.read_secrets().get("PHONE_PIN", "")
    if not pin:
        die(
            f"PHONE_PIN is empty (set it in {settings.PHONE_SECRETS} or the "
            "environment)"
        )
    if not pin.isdigit():
        die("PHONE_PIN must be digits only")
    return pin


def _lock_screen(serial: str) -> tuple[bool | None, bool]:
    """(locked, awake) from one `dumpsys window policy`.

    Both answers come from the same block, so a wake-and-check loop costs one
    round trip per look. `locked` is None when the build does not say, which
    callers treat as "cannot tell" rather than "unlocked". A build that omits
    the screen fields counts as awake: the PIN is then still tried, which is
    better than refusing to unlock over a missing line.
    """
    fields: dict[str, str] = {}
    # The dump can come back empty or cut short (a busy phone closes the pipe),
    # and a missing `showing` line is worth another read rather than an error.
    for attempt in range(3):
        for line in (
            capture(["adb", "-s", serial, "shell", "dumpsys", "window", "policy"])
            .replace("\r", "")
            .splitlines()
        ):
            match = re.match(r" *(showing|screenState|interactiveState)=(\S+)$", line)
            if match:
                fields[match.group(1)] = match.group(2)
        if "showing" in fields:
            break
        if attempt < 2:
            time.sleep(0.3)
    locked = {"true": True, "false": False}.get(fields.get("showing", ""))
    awake = fields.get("screenState") != "SCREEN_STATE_OFF"
    return locked, awake


def _wake(serial: str, timeout: float = 4.0) -> bool:
    """Wake the panel and confirm it came up.

    A single KEYCODE_WAKEUP is what made this flaky: the press can land while
    the display is still powering on, leaving the screen off and the keyguard
    untouched. Send it again until the screen reports itself on.
    """
    deadline = time.monotonic() + timeout
    while True:
        must(["adb", "-s", serial, "shell", "input", "keyevent", "KEYCODE_WAKEUP"])
        _, awake = _lock_screen(serial)
        if awake:
            return True
        if time.monotonic() >= deadline:
            return False
        time.sleep(0.5)


def _swipe_up(serial: str) -> None:
    """Drag the lock screen up, using the panel size the phone reports."""
    size = _phone_shell(serial, "wm", "size")
    match = re.search(r"^Physical size: (\d+)x(\d+)", size, re.MULTILINE)
    if match:
        width, height = int(match.group(1)), int(match.group(2))
    else:
        width, height = 1440, 3200
    x = width // 2
    must(
        [
            "adb",
            "-s",
            serial,
            "shell",
            "input",
            "swipe",
            str(x),
            str(height * 78 // 100),
            str(x),
            str(height * 22 // 100),
            "250",
        ]
    )


def phone_unlock(args: list[str]) -> int:
    """Unlock the phone's lock screen."""
    _only_help([value for value in args if value != "--check"], USAGE_UNLOCK)
    check_only = "--check" in args

    serial = phone.phone_serial()
    if not serial:
        die("no phone attached (see adb devices)")

    locked, awake = _lock_screen(serial)
    if locked is None:
        die(
            "cannot read the keyguard state over adb (is the device still "
            "listed by `adb devices`?)"
        )
    if not locked and awake:
        log("phone is already unlocked")
        return 0
    if check_only:
        log("phone is locked" if locked else "phone is asleep")
        return 1

    pin = _pin()

    log("phone is locked; waking it and entering the PIN")
    # Three passes instead of one: a swipe that lands during the keyguard
    # animation, or a digit the bouncer drops while it is still sliding in,
    # costs one attempt rather than the whole command.
    for _ in range(3):
        if not _wake(serial):
            die("the screen did not wake up (screenState stayed off)")
        # Unlocks a swipe-only keyguard outright and brings up the PIN bouncer
        # on a secure one, so the swipe below is not always needed.
        run(["adb", "-s", serial, "shell", "wm", "dismiss-keyguard"])
        locked, awake = _lock_screen(serial)
        if not locked and awake:
            log("unlocked")
            return 0

        _swipe_up(serial)
        time.sleep(1)
        must(["adb", "-s", serial, "shell", "input", "text", pin])
        must(["adb", "-s", serial, "shell", "input", "keyevent", "KEYCODE_ENTER"])

        for _ in range(5):
            time.sleep(1)
            locked, awake = _lock_screen(serial)
            if not locked and awake:
                log("unlocked")
                return 0
        # Leave the bouncer's error state before typing the PIN again.
        run(["adb", "-s", serial, "shell", "input", "keyevent", "KEYCODE_BACK"])
        time.sleep(0.5)

    die(
        "still locked after entering the PIN 3 times (wrong PIN, or the lock "
        "screen keeps coming back)"
    )
    return 1


def phone_reboot_unlock(args: list[str]) -> int:
    """Reboot the phone and unlock it once."""
    assume_yes = False
    for value in args:
        if value == "--yes":
            assume_yes = True
        elif value in ("-h", "--help"):
            print(USAGE_REBOOT, end="", file=sys.stderr)
            return 0
        else:
            print(USAGE_REBOOT, end="", file=sys.stderr)
            die(f"unknown argument: {value}")

    serial = phone.phone_serial()
    if not serial:
        die("no phone attached (see adb devices)")
    unlock = ui.unlock_bin()
    if not unlock:
        die("phone-unlock not found next to this script or in PATH")

    if not assume_yes and not _confirm_tty(f"Reboot {serial} now? [y/N] "):
        die("aborted")

    poll = float(os.environ.get("PHONE_REBOOT_POLL") or "2")
    limit = float(os.environ.get("PHONE_REBOOT_TIMEOUT") or "240")

    # The old session still reports device and boot_completed for a moment
    # after `adb reboot`, so the new boot id is what proves the phone actually
    # restarted.
    boot_id = _phone_shell(serial, "cat", "/proc/sys/kernel/random/boot_id") or "unknown"

    log(f"rebooting {serial}")
    must(["adb", "-s", serial, "reboot"])

    log("waiting for the phone to come back")
    waited = 0.0
    while True:
        current = _phone_shell(
            serial, "cat", "/proc/sys/kernel/random/boot_id"
        )
        if capture(["adb", "-s", serial, "get-state"]) == "device" and current != boot_id:
            break
        time.sleep(poll)
        waited += poll
        if waited >= limit:
            die(f"the phone did not come back within {limit:.0f}s")

    log("waiting for Android to finish booting")
    while True:
        if _phone_shell(serial, "getprop", "sys.boot_completed") == "1":
            break
        time.sleep(poll)
        waited += poll
        if waited >= limit:
            die(f"Android did not finish booting within {limit:.0f}s")

    # phone-unlock can run before the keyguard is drawn, so give it a few
    # tries.
    tries = 0
    while run([unlock]) != 0:
        tries += 1
        if tries >= 3:
            die("the phone booted but could not be unlocked")
        time.sleep(poll)

    log("phone rebooted and unlocked")
    return 0


def _tool(name: str) -> str:
    from .. import actions

    return actions.binary(actions.BY_ID[name])


def phone_tether_cycle(args: list[str]) -> int:
    """Cycle USB tethering around the internet health check."""
    assume_yes = False
    for value in args:
        if value == "--yes":
            assume_yes = True
        elif value in ("-h", "--help"):
            print(USAGE_CYCLE, end="", file=sys.stderr)
            return 0
        else:
            print(USAGE_CYCLE, end="", file=sys.stderr)
            die(f"unknown argument: {value}")

    net_check = os.environ.get("PHONE_NET_CHECK") or _tool("net-check")
    tether_check = os.environ.get("PHONE_TETHER_CHECK") or _tool(
        "phone-usb-tether-check"
    )
    for tool in (net_check, tether_check):
        if not os.access(tool, os.X_OK):
            die(f"missing helper: {tool}")
    unlock = os.environ.get("PHONE_UNLOCK") or ui.unlock_bin() or ""
    if not unlock or not os.access(unlock, os.X_OK):
        die("phone-unlock not found (set PHONE_UNLOCK)")

    disable_tries = int(os.environ.get("PHONE_DISABLE_TRIES") or "15")
    restore_tries = int(os.environ.get("PHONE_RESTORE_TRIES") or "5")
    restore_wait = float(os.environ.get("PHONE_RESTORE_WAIT") or "2")

    serial = phone.phone_serial()
    if not serial:
        die("no phone attached (see adb devices)")

    def usb_config() -> str:
        output = _phone_shell(serial, "getprop", "sys.usb.config")
        return output.splitlines()[0] if output.splitlines() else ""

    def has_rndis(value: str) -> bool:
        return "rndis" in value.lower()

    if not assume_yes and not _confirm_tty(
        f"Disable USB tethering briefly on {serial}? [y/N] "
    ):
        die("aborted")

    restored = False

    def restore() -> bool:
        nonlocal restored
        if restored:
            return True
        log("restoring USB tethering")
        tries = 0
        while tries < restore_tries:
            # The framework ignores data functions while locked and applies the
            # screen-unlocked ones on unlock, so set that default first, force
            # the keyguard and then unlock.
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
            status(["adb", "-s", serial, "shell", "svc", "usb", "setFunctions"])
            status(
                ["adb", "-s", serial, "shell", "input", "keyevent", "KEYCODE_SLEEP"]
            )
            waited = 0
            while not ui.keyguard(serial) and waited < 5:
                time.sleep(1)
                waited += 1
            run([unlock])
            time.sleep(restore_wait)
            if status([tether_check]) == 0:
                restored = True
                return True
            tries += 1
        log("warning: USB tethering is still off")
        return False

    try:
        current = usb_config()
        if has_rndis(current):
            log("disabling USB tethering (switching to MTP, adb stays up)")
            tries = 0
            while has_rndis(usb_config()):
                # "adb" alone is rejected here and the adb client may abort
                # while the gadget re-enumerates, so re-issue a function the
                # phone accepts.
                status(
                    ["adb", "-s", serial, "shell", "svc", "usb", "setFunctions", "mtp"]
                )
                time.sleep(1)
                tries += 1
                if tries >= disable_tries:
                    die(f"USB tethering did not turn off (usb={usb_config()})")
            off_config = usb_config()
        else:
            off_config = current
            log(f"USB tethering was already off (usb={current})")

        log("running the internet health check")
        completed = run([net_check], timeout=600)
        if completed != 0:
            log("the internet health check failed")
        else:
            log("the internet health check passed")

        log("enabling USB tethering again")
        if not restore():
            die(
                "could not restore USB tethering (phone-unlock needs PHONE_PIN, "
                "so run with sudo)"
            )

        log(
            f"tether cycle: off (usb={off_config}), health check exit "
            f"{completed}, on (usb={usb_config()}, route healthy)"
        )
        if completed == 0:
            log("the laptop kept internet while tethering was off")
        else:
            log(
                "the laptop had no internet while tethering was off "
                "(expected when the tether is the uplink)"
            )
        return 0
    finally:
        if not restored:
            restore()
