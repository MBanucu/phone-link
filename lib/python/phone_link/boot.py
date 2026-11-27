"""What the proxy app needs in order to start before the first unlock.

`dumpsys package` answers all of it without the APK: the runtime grants, the
normal boot permission, the package's direct-boot flag and the receiver table.
The doctor's `app_boot` check and `phone-proxy-boot` both read it through this
module, so the check and the fixer cannot disagree about what "will come back
at boot" means.

Two kinds of missing fact are kept apart on purpose:

* a permission the build declares but the store or a wipe left ungranted is
  fixable from adb, and the fixer grants it;
* a permission the dump does not mention, a missing direct-boot flag or a
  missing locked-boot receiver is a property of the installed APK. Only
  reinstalling the right release fixes it, and the message says so.

Nothing here proves the boot itself. That is a live fact: reboot the phone, do
not unlock it, and check that the listener answers (see
`tests/live/hairpin-measure.sh --bootstrap`). A doctor run can only say that
every input the boot start is known to need is present.
"""

from __future__ import annotations

import re

# Android's own permission names, without the `android.permission.` prefix.
LOCATION_PERMISSIONS = ("ACCESS_COARSE_LOCATION", "ACCESS_FINE_LOCATION")
BACKGROUND_LOCATION = "ACCESS_BACKGROUND_LOCATION"
NOTIFICATIONS = "POST_NOTIFICATIONS"
BOOT_PERMISSION = "RECEIVE_BOOT_COMPLETED"

LOCKED_BOOT = "android.intent.action.LOCKED_BOOT_COMPLETED"
DIRECT_BOOT_FLAGS = re.compile(
    r"(?<![A-Z_])(?:PARTIALLY_)?DIRECT_BOOT_AWARE(?![A-Z_])"
)

_DENIED = {
    "ACCESS_COARSE_LOCATION": "coarse location is not granted",
    "ACCESS_FINE_LOCATION": "fine location is not granted",
    "ACCESS_BACKGROUND_LOCATION": "background location is not granted",
    "POST_NOTIFICATIONS": "notifications are not granted (the boot notice is hidden)",
}

_UNDECLARED = {
    "ACCESS_COARSE_LOCATION": "the build does not declare coarse location",
    "ACCESS_FINE_LOCATION": "the build does not declare fine location",
    "ACCESS_BACKGROUND_LOCATION": "the build does not declare background location",
    "POST_NOTIFICATIONS": "the build does not declare notifications",
}


def granted(dumpsys: str, permission: str) -> str:
    """`true`, `false`, or "" when the dump does not mention the permission.

    Empty is not "denied": it means the installed APK never requested it, which
    is a manifest fact and cannot be repaired with `pm grant`.
    """
    match = re.search(
        rf"android\.permission\.{re.escape(permission)}:\s*granted=(true|false)",
        dumpsys,
    )
    return match.group(1) if match else ""


def auto_start_state(service_dump: str, state_text: str = "") -> str:
    """`auto-start` from the running service, or from the app's state file.

    A stopped service prints nothing for `dumpsys activity service`, and a
    stopped service is exactly what a phone that did not come back looks like.
    The app writes its switches to `files/state.txt` on every change, so the
    answer is still there.
    """
    match = re.search(r"auto-start\s+(true|false)", service_dump)
    if match:
        return match.group(1)
    return _state_value(state_text, "auto_start")


def _state_value(state_text: str, key: str) -> str:
    """The value of one `key value` line in the app's state file, or ""."""
    for line in state_text.splitlines():
        name, _, value = line.partition(" ")
        if name.strip() == key:
            return value.strip()
    return ""


def oem_autostart_state(state_text: str = "") -> str:
    """`unreadable` when the app says it cannot read the DokeOS list, or "".

    The vendor list is behind a signature permission, so `unreadable` is the
    only positive fact a current app can report about it. An older app that
    does not write the line at all is a different unknown, and neither is
    "open": the caller must never turn this into a pass.
    """
    return _state_value(state_text, "oem_autostart")


def last_boot_missed(state_text: str = "") -> str:
    """The app's dated observation of a boot with no broadcast, or "".

    The line is `last_boot no_broadcast <epoch seconds>` and only exists when
    the app's boot receiver did not run in the current boot while auto-start
    was on. It records the observation, not a cause; the caller may say
    "likely blocked", because the vendor list cannot be read.

    Older or unknown spellings — including a `last_boot blocked <epoch>` line
    that states the suspicion — are deliberately ignored: they are not proof,
    and the doctor falls back to "unknown".
    """
    parts = _state_value(state_text, "last_boot").split()
    if len(parts) < 2 or parts[0] != "no_broadcast":
        return ""
    return parts[1]


def notifications_required(dumpsys: str, device_sdk: str = "") -> bool:
    """API 33+ hides the foreground-service notice without the grant."""
    match = re.search(r"targetSdk=(\d+)", dumpsys)
    if match:
        return int(match.group(1)) >= 33
    device = (device_sdk or "").strip()
    return device.isdigit() and int(device) >= 33


def direct_boot_aware(dumpsys: str) -> bool:
    """The package is (partially) direct-boot aware.

    Only the package's own flags count. A component's `DIRECT_BOOT_AWARE` is
    not enough: the application has to be aware for the process to start
    before the credential-encrypted storage is unlocked.
    """
    flags = " ".join(
        match.group(1)
        for match in re.finditer(
            r"^ {0,4}(?:privatePkgFlags|privateFlags|flags)=\[([^\]]*)\]",
            dumpsys,
            re.MULTILINE,
        )
    )
    return bool(DIRECT_BOOT_FLAGS.search(flags))


def locked_boot_receiver(dumpsys: str) -> str:
    """The component registered for LOCKED_BOOT_COMPLETED, or "".

    The receiver table is parsed as a block so an activity filter that happens
    to mention the action cannot stand in for a receiver.
    """
    match = re.search(r"^Receiver Resolver Table:[ \t]*$", dumpsys, re.MULTILINE)
    if not match:
        return ""
    rest = dumpsys[match.end():]
    end = re.search(r"^\S.*Resolver Table:[ \t]*$", rest, re.MULTILINE)
    block = rest[: end.start()] if end else rest
    entry = re.search(
        rf"^[ \t]*{re.escape(LOCKED_BOOT)}:[ \t]*\n[ \t]+\S+[ \t]+(\S+)",
        block,
        re.MULTILINE,
    )
    return entry.group(1) if entry else ""


def grants_needed(dumpsys: str, device_sdk: str = "") -> list[str]:
    """The declared-but-denied permissions, in the fixer's grant order.

    Background location comes after fine location, and notifications only when
    the app targets API 33 or newer.
    """
    needed = [
        permission
        for permission in (*LOCATION_PERMISSIONS, BACKGROUND_LOCATION)
        if granted(dumpsys, permission) == "false"
    ]
    if notifications_required(dumpsys, device_sdk):
        if granted(dumpsys, NOTIFICATIONS) == "false":
            needed.append(NOTIFICATIONS)
    return needed


def inspect(
    dumpsys: str,
    device_sdk: str = "",
    auto_start: str = "",
    whitelisted: bool = True,
) -> tuple[list[str], list[str], list[str]]:
    """`(fixable, reinstall, unknown)` problems, as phrases for a message.

    `fixable` is what `phone-proxy-boot` can change: the allowlist, auto_start
    and a declared-but-denied grant. `reinstall` is a property of the APK.
    `unknown` is a fact the dump did not answer; the doctor warns instead of
    failing so a stopped service does not turn into a false alarm.
    """
    fixable: list[str] = []
    reinstall: list[str] = []
    unknown: list[str] = []

    if auto_start == "false":
        fixable.append("auto_start is off")
    elif auto_start != "true":
        unknown.append(
            "auto_start could not be read (neither the service nor its state "
            "file answered)"
        )

    if not whitelisted:
        fixable.append("not on the battery allowlist")

    for permission in (*LOCATION_PERMISSIONS, BACKGROUND_LOCATION):
        state = granted(dumpsys, permission)
        if state == "false":
            fixable.append(_DENIED[permission])
        elif state != "true":
            reinstall.append(_UNDECLARED[permission])

    if notifications_required(dumpsys, device_sdk):
        state = granted(dumpsys, NOTIFICATIONS)
        if state == "false":
            fixable.append(_DENIED[NOTIFICATIONS])
        elif state != "true":
            reinstall.append(_UNDECLARED[NOTIFICATIONS])

    if granted(dumpsys, BOOT_PERMISSION) != "true":
        reinstall.append("RECEIVE_BOOT_COMPLETED is not granted")

    if not direct_boot_aware(dumpsys):
        reinstall.append("this build is not direct-boot aware")
    elif not locked_boot_receiver(dumpsys):
        reinstall.append("no receiver handles LOCKED_BOOT_COMPLETED")

    return fixable, reinstall, unknown
