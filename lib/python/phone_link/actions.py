"""The action registry: one entry per script in ../bin.

The GUI renders this table, `phone-link run` executes it, and the flake's
`registry` check fails when a script has no entry. "Every CLI action is in the
GUI" is therefore enforced by a check rather than by remembering to add it.

Flags are declared, not guessed: `supports_check` drives the "Check only"
entry, `supports_yes` decides whether a confirmed GUI run adds `--yes`, and
`root` decides whether the run goes through pkexec.
"""

from __future__ import annotations

import os
import shutil
from dataclasses import dataclass
from pathlib import Path

GROUPS: tuple[tuple[str, str], ...] = (
    ("status", "Status"),
    ("tunnel", "Tunnel"),
    ("ap", "Access point"),
    ("phone", "Phone and adb"),
    ("proxy", "Proxy app"),
    ("maintenance", "Maintenance"),
)

GROUP_ICONS = {
    "status": "utilities-system-monitor-symbolic",
    "tunnel": "network-transmit-receive-symbolic",
    "ap": "network-wireless-symbolic",
    "phone": "phone-symbolic",
    "proxy": "preferences-system-network-symbolic",
    "maintenance": "applications-system-symbolic",
}


@dataclass(frozen=True)
class Variant:
    """One non-default way to call an action."""

    label: str
    args: tuple[str, ...] = ()
    check: bool = False


@dataclass(frozen=True)
class Action:
    id: str
    group: str
    title: str
    summary: str
    root: bool = False
    supports_check: bool = False
    supports_yes: bool = False
    destructive: bool = False
    long_running: bool = False
    confirm: str = ""
    variants: tuple[Variant, ...] = ()

    @property
    def needs_confirm(self) -> bool:
        return self.destructive or bool(self.confirm)


ACTIONS: tuple[Action, ...] = (
    # -- status --------------------------------------------------------
    Action(
        "phone-net-status",
        "status",
        "Overview",
        "Links, routes, resolver, proxy probes, adb transports and phone state.",
    ),
    Action(
        "phone-doctor",
        "status",
        "Doctor",
        "Check every runtime condition of the setup. Read-only.",
        supports_check=False,
    ),
    Action(
        "net-check",
        "status",
        "Internet check",
        "Fetch a fresh URL with curl, Chrome and Nix and report which reach it.",
    ),
    Action(
        "phone-proxy-check",
        "status",
        "Proxy probe",
        "Request through the proxy on the hotspot and AP addresses.",
        root=True,
    ),
    Action(
        "phone-usb-tether-check",
        "status",
        "USB tether check",
        "Report whether tethering is active and HTTPS answers over that route.",
    ),
    Action(
        "phone-wifi-concurrency",
        "status",
        "Wi-Fi concurrency",
        "Report whether the phone runs a Wi-Fi client and hotspot at once.",
    ),
    # -- tunnel --------------------------------------------------------
    Action(
        "phone-fix-tunnel",
        "tunnel",
        "Start or restart the tunnel",
        "Start phone-tun, or restart it when its route is missing, then wait.",
        root=True,
        supports_check=True,
    ),
    Action(
        "phone-tunnel-run",
        "tunnel",
        "Run the tunnel in the foreground",
        "Run the built sing-box config until it is stopped.",
        root=True,
        long_running=True,
        confirm="This replaces the managed tunnel with a foreground run.",
        variants=(Variant("Upstream through adb reverse", ("--via-adb",)),),
    ),
    # -- access point --------------------------------------------------
    Action(
        "phone-ap-up",
        "ap",
        "Bring the access point up",
        "Preflight the radio, then activate the phonelink AP profile.",
        root=True,
    ),
    Action(
        "phone-ap-down",
        "ap",
        "Drop the access point",
        "Stop the AP and rejoin the phone's own hotspot.",
        root=True,
        destructive=True,
        confirm="The phone leaves the laptop's access point and rejoins its hotspot.",
    ),
    Action(
        "phone-ap-create",
        "ap",
        "Create the AP profile",
        "Build the phonelink profile from the root-only PHONE_AP_PASS secret.",
        root=True,
        supports_check=True,
        variants=(Variant("Rewrite profile and PSK", ("--refresh",)),),
    ),
    Action(
        "phone-ap-delete",
        "ap",
        "Delete the AP profile",
        "Remove the phonelink profile from NetworkManager, down first if active.",
        root=True,
        supports_check=True,
        supports_yes=True,
        destructive=True,
        confirm="Delete the AP profile? A declared profile comes back at boot.",
    ),
    Action(
        "phone-fix-forwarding",
        "ap",
        "Enable IPv4 forwarding",
        "Set net.ipv4.ip_forward=1 for the running kernel.",
        root=True,
        supports_check=True,
    ),
    Action(
        "phone-wifi-connect",
        "ap",
        "Join PhoneLink from the phone",
        "Connect the phone's Wi-Fi client to PhoneLink with WPA2 and wait.",
        root=True,
        supports_check=True,
    ),
    Action(
        "phone-wifi-enable",
        "ap",
        "Enable phone Wi-Fi",
        "Turn the phone's Wi-Fi radio on and wait until Android reports it.",
        supports_check=True,
    ),
    Action(
        "phone-wifi-forget",
        "ap",
        "Forget a saved network",
        "Forget PhoneLink on the phone so the next join starts clean.",
        supports_check=True,
        supports_yes=True,
        destructive=True,
        confirm="The phone forgets the saved PhoneLink network.",
    ),
    # -- phone and adb -------------------------------------------------
    Action(
        "phone-adb-wifi",
        "phone",
        "Enable adb over Wi-Fi",
        "Turn on the legacy port or Android 11+ wireless debugging, then connect.",
        supports_check=True,
        variants=(
            Variant("Legacy TCP port only", ("--legacy",)),
            Variant("Wireless debugging only", ("--tls",)),
        ),
    ),
    Action(
        "adb-wifi-connect",
        "phone",
        "Connect adb over TCP",
        "Connect adb to whichever phone address answers.",
        variants=(Variant("Prepare over USB first", ("--prepare",)),),
    ),
    Action(
        "phone-unlock",
        "phone",
        "Unlock the phone",
        "Wake, swipe and enter the PIN from the root-only secrets file.",
        root=True,
        supports_check=True,
    ),
    Action(
        "phone-reboot-unlock",
        "phone",
        "Reboot and unlock",
        "Reboot the phone, wait for boot, then unlock it once.",
        root=True,
        supports_yes=True,
        destructive=True,
        long_running=True,
        confirm="Reboot the phone now? adb and the tether drop until it is back.",
    ),
    Action(
        "phone-usb-tether-default",
        "phone",
        "Default USB action to tethering",
        "Set rndis,adb as the USB function and on screen unlock.",
        supports_check=True,
    ),
    Action(
        "phone-tether-cycle",
        "phone",
        "Cycle USB tethering",
        "Switch USB to MTP, check the internet, then restore the tether.",
        root=True,
        supports_yes=True,
        destructive=True,
        long_running=True,
        confirm="Lock and unlock the phone to restore the tether?",
    ),
    Action(
        "phone-fix-mobile-data",
        "phone",
        "Enable mobile data",
        "Turn the phone's mobile data on and wait for a default route.",
        supports_check=True,
    ),
    Action(
        "phone-fix-internet",
        "phone",
        "Restore internet",
        "Try mobile data, USB tethering, then the phone hotspot, verifying HTTPS.",
        root=True,
        supports_check=True,
        long_running=True,
    ),
    # -- proxy app -----------------------------------------------------
    Action(
        "phone-proxy-install",
        "proxy",
        "Install the proxy app",
        "Install or update the proxy APK over adb.",
        supports_check=True,
        variants=(
            Variant("Download from F-Droid", ("--fdroid",)),
            Variant("Only report the installed version", ("--status",)),
        ),
    ),
    Action(
        "phone-proxy-uninstall",
        "proxy",
        "Uninstall the proxy app",
        "Remove the proxy app; the tunnel falls back to the normal route.",
        supports_check=True,
        supports_yes=True,
        destructive=True,
        confirm="Uninstall the proxy app from the phone?",
    ),
    Action(
        "phone-proxy-setup",
        "proxy",
        "Configure the proxy app",
        "Write port, credentials and auto-start through the app's settings screen.",
        root=True,
        supports_check=True,
        long_running=True,
    ),
    Action(
        "phone-proxy-start",
        "proxy",
        "Start the proxy",
        "Unlock the phone, open the app and tap Start, then wait for it.",
        root=True,
        supports_check=True,
    ),
    Action(
        "phone-proxy-stop",
        "proxy",
        "Stop the proxy",
        "Unlock the phone, open the app and tap Stop, then wait for it.",
        root=True,
        supports_check=True,
    ),
    Action(
        "phone-proxy-data-clear",
        "proxy",
        "Clear proxy app data",
        "Reset the app to port 1080 with no auth; the proxy stops.",
        supports_check=True,
        supports_yes=True,
        destructive=True,
        confirm="Clear the proxy app's data? Port and credentials are lost.",
    ),
    Action(
        "phone-proxy-battery-whitelist",
        "proxy",
        "Exempt the proxy from Doze",
        "Add the app to the device-idle whitelist so Doze cannot kill it.",
        supports_check=True,
    ),
    # -- maintenance ---------------------------------------------------
    Action(
        "phone-doctor-fix",
        "maintenance",
        "Repair reported problems",
        "Run the fix script for each problem the doctor reports, then re-check.",
        root=True,
        supports_yes=True,
        supports_check=True,
        long_running=True,
        confirm="Apply the fixes the doctor reports?",
        variants=(Variant("Only required problems", ("--required",)),),
    ),
    Action(
        "phone-fix-apk",
        "maintenance",
        "Stock the ambulance APK",
        "Cache the proxy APK so the app can be reinstalled without a network.",
        root=True,
        supports_check=True,
        long_running=True,
        variants=(Variant("Always download the newest", ("--refresh",)),),
    ),
    Action(
        "phone-link-uninstall",
        "maintenance",
        "Remove runtime state",
        "Delete the AP profile and APK caches after unwiring the module.",
        root=True,
        supports_check=True,
        supports_yes=True,
        destructive=True,
        confirm="Remove the AP profile and the cached APKs?",
        variants=(Variant("Keep the APK caches", ("--keep-cache",)),),
    ),
)

BY_ID: dict[str, Action] = {action.id: action for action in ACTIONS}


def actions_in(group: str) -> list[Action]:
    return [action for action in ACTIONS if action.group == group]


def binary(action: Action) -> str:
    """The script's path: PATH first, then the checkout next to this package."""
    found = shutil.which(action.id)
    if found:
        return found
    root = Path(__file__).resolve().parents[3]
    candidate = root / "bin" / action.id
    return str(candidate) if candidate.is_file() else action.id


def doctor_bin() -> str | None:
    override = os.environ.get("PHONE_DOCTOR")
    if override:
        return override
    found = shutil.which("phone-doctor")
    if found:
        return found
    # The store install keeps every script under share/phone-link/bin, so a
    # store-path call (a flake check, or the GUI without a shell PATH) still
    # finds the doctor next to this package.
    root = Path(__file__).resolve().parents[3]
    candidate = root / "bin" / "phone-doctor"
    return str(candidate) if candidate.is_file() else None


def plan(
    action: Action,
    *,
    args: tuple[str, ...] = (),
    check: bool = False,
    assume_yes: bool = False,
    escalate: bool | None = None,
    env: dict[str, str] | None = None,
) -> list[str]:
    """The argv for one run, including the flags and escalation it implies."""
    argv = [binary(action), *args]
    if check:
        if not action.supports_check:
            raise ValueError(f"{action.id} has no --check")
        argv.append("--check")
    if assume_yes and action.supports_yes and not check:
        argv.append("--yes")
    if escalate is None:
        escalate = action.root
    if escalate and os.geteuid() != 0:
        pkexec = shutil.which("pkexec")
        if pkexec:
            # pkexec sanitises the environment, so pass the PHONE_* overrides
            # the scripts document as their configuration.
            values = env if env is not None else os.environ
            pairs = [
                f"{key}={value}"
                for key, value in sorted(values.items())
                if key.startswith("PHONE_")
            ]
            argv = [pkexec, "env", *pairs, *argv]
    return argv


def validate(expected: tuple[str, ...] | list[str] = ()) -> list[str]:
    """Problems with the registry, for the flake's checks and `check-registry`."""
    problems: list[str] = []
    ids = [action.id for action in ACTIONS]
    duplicates = sorted({name for name in ids if ids.count(name) > 1})
    if duplicates:
        problems.append("duplicate ids: " + ", ".join(duplicates))

    group_ids = {group for group, _ in GROUPS}
    for action in ACTIONS:
        if action.group not in group_ids:
            problems.append(f"{action.id}: unknown group {action.group}")
        program = binary(action)
        if not os.access(program, os.X_OK):
            problems.append(f"{action.id}: not executable ({program})")
        for variant in action.variants:
            if variant.check and not action.supports_check:
                problems.append(f"{action.id}: variant {variant.label} needs --check")

    if expected:
        missing = sorted(set(expected) - set(ids))
        extra = sorted(set(ids) - set(expected))
        if missing:
            problems.append("no action for: " + ", ".join(missing))
        if extra:
            problems.append("action without a script: " + ", ".join(extra))
    return problems
