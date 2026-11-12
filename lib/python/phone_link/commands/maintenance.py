"""Maintenance commands: remove the runtime state phone-link leaves behind."""

from __future__ import annotations

import os
import shutil
import sys

from .. import phone, settings
from ..shell import capture, die, log, status

USAGE_UNINSTALL = """usage: phone-link-uninstall [--yes] [--check] [--keep-cache]

Stops the phone-link tunnel units, deletes the phonelink NetworkManager
profile (including a hand-made copy) and clears /var/cache/phone-link plus the
invoking user's ~/.cache/phone-link. --check only reports; --yes skips the
confirmation; --keep-cache leaves the APKs alone. Keep this script in the
checkout: unwiring the flake removes the installed copy.
"""


def _profile_exists() -> bool:
    return settings.PHONE_AP_CON in capture(
        ["nmcli", "-t", "-f", "NAME", "con", "show"]
    ).splitlines()


def _active_device() -> str:
    for line in capture(
        ["nmcli", "-t", "-f", "NAME,DEVICE", "con", "show", "--active"]
    ).splitlines():
        name, _, device = line.partition(":")
        if name == settings.PHONE_AP_CON:
            return device
    return ""


def _user_cache() -> str | None:
    """The invoking user's cache, when the run came through sudo."""
    user = os.environ.get("SUDO_USER")
    if not user:
        return None
    try:
        with open("/etc/passwd", encoding="utf-8") as passwd:
            for line in passwd:
                fields = line.split(":")
                if fields[0] == user and len(fields) > 5:
                    return os.path.join(fields[5], ".cache", "phone-link")
    except OSError:
        return None
    return None


def phone_link_uninstall(args: list[str]) -> int:
    """Remove the AP profile, the units and the cached APKs."""
    assume_yes = False
    check_only = False
    keep_cache = False
    for value in args:
        if value in ("-y", "--yes"):
            assume_yes = True
        elif value == "--check":
            check_only = True
        elif value == "--keep-cache":
            keep_cache = True
        elif value in ("-h", "--help"):
            print(USAGE_UNINSTALL, end="", file=sys.stderr)
            return 0
        else:
            print(USAGE_UNINSTALL, end="", file=sys.stderr)
            die(f"unknown argument: {value}")

    cache = _user_cache()
    if check_only:
        if _profile_exists():
            device = _active_device()
            suffix = f" and is active on {device}" if device else ""
            log(f"{settings.PHONE_AP_CON} exists{suffix}")
        else:
            log(f"{settings.PHONE_AP_CON} is not configured")
        if phone.ap_declarative():
            log(
                f"phoneLink.ap still declares {settings.PHONE_AP_CON}; "
                "remove it before uninstalling"
            )
        if os.path.isdir(settings.PHONE_APK_CACHE):
            log(f"cache {settings.PHONE_APK_CACHE} exists")
        else:
            log(f"cache {settings.PHONE_APK_CACHE} is absent")
        if cache and os.path.isdir(cache):
            log(f"cache {cache} exists")
        if os.access(settings.PHONE_SECRETS, os.R_OK):
            log(f"{settings.PHONE_SECRETS} is kept")
        return 0

    if phone.ap_declarative():
        die(
            f"phoneLink.ap still declares {settings.PHONE_AP_CON}; remove it "
            "from configuration.nix and run nixos-rebuild switch first"
        )

    phone.as_root("phone-link-uninstall", args)

    if not assume_yes:
        if not sys.stdin.isatty():
            die("refusing to remove without --yes (not a terminal)")
        sys.stderr.write("Remove the phone-link AP profile and caches? [y/N] ")
        sys.stderr.flush()
        if sys.stdin.readline().strip() not in ("y", "Y", "yes", "YES"):
            log("aborted")
            return 1

    # Stop the timer before the services it starts, so nothing comes back while
    # the AP is being removed.
    for unit in (
        "phone-tun-toggle.timer",
        "phone-tun-toggle.service",
        "phone-tun.service",
    ):
        status(["systemctl", "stop", unit])

    if _profile_exists():
        device = _active_device()
        if device:
            log(f"bringing {settings.PHONE_AP_CON} down (active on {device})")
            status(["nmcli", "connection", "down", settings.PHONE_AP_CON])
        # A declarative and a hand-made profile can share the name; delete
        # until none is left, then remove any keyfile NetworkManager did not
        # own.
        for _ in range(3):
            if not _profile_exists():
                break
            if status(["nmcli", "connection", "delete", settings.PHONE_AP_CON]) != 0:
                break

    for directory in (
        settings.PHONE_NM_SYSTEM_CONNECTIONS,
        settings.PHONE_NM_RUN_CONNECTIONS,
    ):
        try:
            os.unlink(
                os.path.join(directory, f"{settings.PHONE_AP_CON}.nmconnection")
            )
        except OSError:
            pass
    status(["nmcli", "connection", "reload"])

    if not keep_cache:
        if os.path.exists(settings.PHONE_APK_CACHE):
            log(f"clearing {settings.PHONE_APK_CACHE}")
            shutil.rmtree(settings.PHONE_APK_CACHE, ignore_errors=True)
        if cache and os.path.isdir(cache):
            log(f"clearing {cache}")
            shutil.rmtree(cache, ignore_errors=True)

    log(
        f"removed {settings.PHONE_AP_CON}, stopped the phone-link units "
        "and cleared the cache"
    )
    log(
        f"kept {settings.PHONE_SECRETS}; delete it by hand if its secrets are "
        "no longer needed"
    )
    log(
        "phone-side state is untouched; from the checkout run "
        "./bin/phone-wifi-forget PhoneLink and ./bin/phone-proxy-uninstall"
    )
    return 0
