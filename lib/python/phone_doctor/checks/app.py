"""The app of our own: installed, and will it come back at boot?

The app is the one whose boot restart depends on things outside itself — the
device-idle allowlist, the location grants, notifications, and a manifest that
can start before the first unlock. A phone that serves `200` today can still
come up with no listener tomorrow. The check names exactly which of those facts
is missing; `phone-proxy-boot` fixes the ones adb can change, and the rest name
the reinstall they need.
"""

from __future__ import annotations

from datetime import datetime, timezone

from phone_link import boot

from ..context import Context
from ..model import Result, fail, ok, warn

SECTION = "[app]"

# The one screen and the two drivers that can reach the DokeOS list. The app
# and adb can only name it: the list is behind a signature permission.
AUTOSTART_SCREEN = "System Manager → App Management → Auto Start Management"
ADB_DRIVER = 'wireless-adb-keeper/autostart-allow.sh "Phone link proxy"'
TOGGLE_DRIVER = "phone-link-tools/autotoggle"


def _app(ctx: Context) -> str:
    """The app under test: PHONE_PROXY_PKG names another one (the test build)."""
    return ctx.proxy_pkg


def _service(ctx: Context) -> str:
    """The service component, with the class's own namespace.

    `.ProxyService` is resolved against the manifest package, which is not the
    app's Java package in a renamed build — `org.phonelink.proxy.test` would
    look for a `ProxyService` class of its own and find nothing.
    """
    return f"{_app(ctx)}/{ctx.get('PHONE_APP_NAMESPACE', 'org.phonelink.proxy')}.ProxyService"


def _installed(ctx: Context) -> bool:
    text = ctx.adb("shell", "pm", "path", _app(ctx))
    return any(line.startswith("package:") for line in text.splitlines())


def _state_text(ctx: Context) -> str:
    """The app's own facts, written for a phone whose service is not running."""
    return ctx.adb(
        "shell",
        "cat",
        f"/sdcard/Android/data/{_app(ctx)}/files/state.txt",
    )


def _auto_start(ctx: Context, state_text: str) -> str:
    """The app's stored auto_start: from the service, or from its state file."""
    text = ctx.adb("shell", "dumpsys", "activity", "service", _service(ctx))
    return boot.auto_start_state(text, state_text)


def _noticed(epoch: str) -> str:
    """The app's epoch-second timestamp as a readable UTC instant."""
    try:
        when = datetime.fromtimestamp(int(epoch), tz=timezone.utc)
    except (OverflowError, OSError, ValueError):
        return epoch
    return when.strftime("%Y-%m-%d %H:%M UTC")


def _oem_autostart(state_text: str) -> Result:
    """The vendor gate is never a pass: unreadable is the best fact there is.

    A dated `last_boot no_broadcast` from the app is the only evidence that a
    boot went by without the receiver, and even that is phrased as a suspicion:
    the list itself cannot be read. The observation does not say why, so the
    wording here supplies the conservative interpretation. A missing line, or
    an old `last_boot blocked` line that states the conclusion, is a different
    unknown, not proof.
    """
    missed = boot.last_boot_missed(state_text)
    if missed:
        return warn(
            "app_oem_autostart",
            "OEM autostart",
            f"likely blocked this boot (noticed {_noticed(missed)}); no boot "
            f"broadcast reached the app. Open {AUTOSTART_SCREEN}, or run "
            f"{ADB_DRIVER} / {TOGGLE_DRIVER}",
        )
    if boot.oem_autostart_state(state_text) == "unreadable":
        return warn(
            "app_oem_autostart",
            "OEM autostart",
            "unknown: the DokeOS list is unreadable "
            "(com.freeme.freemanager.permission.ACCESS_INTERFACE); the battery "
            f"exemption is a separate gate. Check {AUTOSTART_SCREEN}, or run "
            f"{ADB_DRIVER} / {TOGGLE_DRIVER}",
        )
    return warn(
        "app_oem_autostart",
        "OEM autostart",
        "unknown: this app does not report the DokeOS gate; update it, then "
        f"check {AUTOSTART_SCREEN}",
    )


def _whitelisted(ctx: Context) -> bool:
    return f",{_app(ctx)}," in ctx.adb("shell", "dumpsys", "deviceidle", "whitelist")


def _ok_detail(dump: str, sdk: str) -> str:
    facts = [
        "auto_start on",
        "allowlisted",
        "fine+coarse location granted",
        "background location granted",
    ]
    if boot.notifications_required(dump, sdk):
        facts.append("notifications granted")
    facts += ["boot_completed granted", "direct boot aware"]
    return ", ".join(facts)


def check(ctx: Context) -> list[Result]:
    if not ctx.serial:
        return [warn("app_installed", "phone-link app", "unknown (no adb)")]

    if not _installed(ctx):
        return [
            fail(
                "app_installed",
                "phone-link app",
                "not installed (phone-proxy-install <apk>)",
            )
        ]

    results: list[Result] = [ok("app_installed", "phone-link app", _app(ctx))]

    dump = ctx.adb("shell", "dumpsys", "package", _app(ctx))
    sdk = ctx.adb("shell", "getprop", "ro.build.version.sdk")
    state_text = _state_text(ctx)
    auto_start = _auto_start(ctx, state_text)
    fixable, reinstall, unknown = boot.inspect(
        dump,
        sdk,
        auto_start,
        _whitelisted(ctx),
    )

    if fixable or reinstall:
        detail = "; ".join(fixable + reinstall)
        if reinstall:
            detail += " (reinstall the release)"
        else:
            detail += " (run phone-proxy-boot)"
        results.append(fail("app_boot", "restarts at boot", detail))
    elif unknown:
        results.append(
            warn(
                "app_boot", "restarts at boot", "allowlisted, but " + "; ".join(unknown)
            )
        )
    else:
        results.append(ok("app_boot", "restarts at boot", _ok_detail(dump, sdk)))
    # Always present when the app is installed: a battery-clear phone still has
    # an unreadable vendor gate, and that must not look like an all-clear.
    results.append(_oem_autostart(state_text))
    return results
