"""Repair paths: internet access, the offline APK kit and mobile data.

These commands may escalate on their own: the APK kit lives under /var/cache,
and the internet repair calls the sibling commands that own the changes.
"""

from __future__ import annotations

import glob
import hashlib
import os
import re
import shlex
import shutil
import sys
import time

from .. import phone, settings
from ..shell import capture, die, log, run, run_text, status
from .common import _first_line, _only_help, _serial, _shell, _tool


USAGE_FIX_INTERNET = """usage: phone-fix-internet [--check] [--help]

Restores internet for the APK download/version check by trying mobile data,
USB tethering and the phone hotspot (the laptop joining as a client), checking
HTTPS after each step. --check only reports whether internet already works.
"""

USAGE_FIX_APK = """usage: phone-fix-apk [--refresh] [--releases [N]] [--check]

Caches this checkout's proxy APK (or PHONE_PROXY_APK) in the ambulance cache
(default /var/cache/phone-link) so a repair can reinstall the app when the tree
is not here: a build is a file, so keeping one is a copy.

--releases also keeps the APKs attached to the newest N releases of this
repository (5 when no number is given) — several versions to fall back on when
the app the phone needs is not the one this tree builds. Each is checked against
the .sha256 the release carries and named after its tag, so two releases of the
same app version do not overwrite each other. Old ones are dropped once the
kit holds more than three times N, oldest first, and the run says which.
--refresh does it too, since activation runs that; --check only lists what the
box holds.
"""

USAGE_MOBILE_DATA = """usage: phone-fix-mobile-data [--check]

Enables mobile data with `svc data enable` and waits for a default route.
--check only reports the route.
"""


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
    time.sleep(3 * settings.PHONE_FIX_SETTLE)
    if _online():
        log("internet is up over mobile data")
        return 0

    log("trying USB tethering")
    serial = phone.phone_serial()
    if not serial:
        die("no phone attached (see adb devices)")
    status(["adb", "-s", serial, "shell", "svc", "usb", "setFunctions", "rndis,adb"])
    if _run_tool("phone-usb-tether-default") != 0:
        log("warning: could not set USB tethering")
    time.sleep(5 * settings.PHONE_FIX_SETTLE)
    if _online():
        log("internet is up over USB tethering")
        return 0

    log("trying the phone hotspot (laptop as a Wi-Fi client)")
    status(["adb", "-s", serial, "shell", "svc", "wifi", "disable"])
    status(
        [
            "adb",
            "-s",
            serial,
            "shell",
            f"cmd wifi start-softap {shlex.quote(settings.PHONE_HOTSPOT_SSID)}",
        ]
    )
    if (
        settings.PHONE_HOTSPOT_CON
        in capture(["nmcli", "-t", "-f", "NAME", "con", "show"]).splitlines()
    ):
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
    time.sleep(10 * settings.PHONE_FIX_SETTLE)
    if _online():
        log("internet is up over the phone hotspot")
        return 0

    die("could not restore internet; connect a working uplink and run phone-net-status")
    return 1


def _releases(limit: int) -> list[tuple[str, str]]:
    """(tag, APK URL) for the newest app releases, newest first."""
    api = (
        f"https://api.github.com/repos/{settings.PHONE_PROXY_REPO}"
        f"/releases?per_page={limit}"
    )
    code, body = run_text(["curl", "-fsSL", "--max-time", "30", api], timeout=40)
    if code != 0:
        return []
    found: list[tuple[str, str]] = []
    for match in re.finditer(
        r'"tag_name"\s*:\s*"([^"]+)"(.*?)(?="tag_name"|\Z)', body, re.S
    ):
        apk = re.search(r'"browser_download_url"\s*:\s*"([^"]+\.apk)"', match.group(2))
        if apk:
            found.append((match.group(1), apk.group(1)))
    return found[:limit]


def _stock_releases(limit: int) -> int:
    """Keep the newest releases' APKs in the box; returns how many are there.

    Every failure here is a warning: this is the repair kit for a host whose
    network may be the thing that is broken, and its absence must not stop the
    build that is already a file here from being kept.
    """
    releases = _releases(limit)
    if not releases:
        log(
            f"warning: cannot read the releases of {settings.PHONE_PROXY_REPO}; "
            "the box keeps what it has"
        )
        return 0
    kept = 0
    for tag, url in releases:
        name = f"{tag}-{url.rsplit('/', 1)[-1]}"
        target = os.path.join(settings.PHONE_APK_CACHE, name)
        if os.path.isfile(target) and os.path.getsize(target) > 0:
            log(f"kept: {name}")
            kept += 1
            continue
        part = f"{target}.part"
        code, _ = run_text(
            ["curl", "-fsSL", "--max-time", "300", "-o", part, url], timeout=330
        )
        if code != 0:
            log(f"warning: cannot download {tag} from {url}")
            continue
        expected = ""
        code, sums = run_text(
            ["curl", "-fsSL", "--max-time", "30", url + ".sha256"], timeout=40
        )
        if code == 0 and sums.strip():
            expected = sums.split()[0]
        with open(part, "rb") as handle:
            digest = hashlib.sha256(handle.read()).hexdigest()
        if expected and digest != expected:
            os.unlink(part)
            log(f"warning: {tag} does not match its checksum; not kept")
            continue
        os.replace(part, target)
        log(f"kept: {name} ({os.path.getsize(target)} bytes)")
        kept += 1
    return kept


def _prune_kit(limit: int) -> list[str]:
    """Drop old release APKs once the kit has grown past three times its size.

    The kit is for falling back a version or two; every release this host has
    ever seen is a museum, and `apk_cached()` picks by mtime, so the ones worth
    keeping are the ones just downloaded. Nothing is dropped while the box is
    small, and what went is named.
    """
    if limit <= 0:
        return []
    kit = sorted(
        (
            path
            for path in glob.glob(os.path.join(settings.PHONE_APK_CACHE, "*.apk"))
            if os.path.basename(path).startswith("v")
        ),
        key=os.path.getmtime,
        reverse=True,
    )
    if len(kit) <= 3 * limit:
        return []
    dropped: list[str] = []
    for path in kit[limit:]:
        try:
            os.unlink(path)
        except OSError:
            continue
        dropped.append(os.path.basename(path))
    return dropped


def phone_fix_apk(args: list[str]) -> int:
    """Stock the ambulance box with a proxy APK that works offline."""
    if any(value in ("-h", "--help") for value in args):
        print(USAGE_FIX_APK, end="", file=sys.stderr)
        return 0
    rest = [
        value for value in args if value not in ("--refresh", "--check", "--releases")
    ]
    if len(rest) > 1 or (rest and not rest[0].isdigit()):
        print(USAGE_FIX_APK, end="", file=sys.stderr)
        die(f"unknown argument: {rest[0]}")
    refresh = "--refresh" in args
    check_only = "--check" in args
    # --refresh is what activation runs, so the kit is refreshed with the build
    # rather than only when somebody remembers to ask for it.
    limit = int(rest[0]) if rest else (5 if ("--releases" in args or refresh) else 0)

    cached = phone.apk_cached()
    if check_only:
        boxed = sorted(glob.glob(os.path.join(settings.PHONE_APK_CACHE, "*.apk")))
        if not boxed:
            log(f"ambulance APK: none cached in {settings.PHONE_APK_CACHE}")
            return 1
        log(f"ambulance APKs: {len(boxed)} in {settings.PHONE_APK_CACHE}")
        for path in boxed:
            log(f"  {path}")
        return 0
    if not refresh and limit == 0 and cached:
        log(f"ambulance APK already stocked: {cached}")
        return 0

    # /var/cache is root-owned; a user run escalates once and redoes the work.
    try:
        os.makedirs(settings.PHONE_APK_CACHE, exist_ok=True)
    except OSError:
        if not phone.is_root():
            phone.as_root("phone-fix-apk", args)
        die(f"cannot create {settings.PHONE_APK_CACHE}")

    source = phone.app_apk()
    if source and not os.path.isfile(source):
        die(f"not a file: {source}")
    if source:
        target = os.path.join(settings.PHONE_APK_CACHE, os.path.basename(source))
        if os.path.abspath(source) == os.path.abspath(target):
            log(f"ambulance APK already stocked: {target}")
        else:
            log(f"copying {source} into {settings.PHONE_APK_CACHE}")
            shutil.copy2(source, target)
            log(f"ambulance APK ready: {target}")
    elif limit == 0:
        die(
            "no APK to cache: run phone-proxy-install --release once, "
            "or name one with PHONE_PROXY_APK"
        )

    if limit:
        kept = _stock_releases(limit)
        log(f"repair kit: {kept} release APK(s) in {settings.PHONE_APK_CACHE}")
        dropped = _prune_kit(limit)
        if dropped:
            log(f"dropped {len(dropped)} old release APK(s): {', '.join(dropped)}")
    return 0


def phone_fix_mobile_data(args: list[str]) -> int:
    """Turn the phone's mobile data on when it has no default route."""
    _only_help([value for value in args if value != "--check"], USAGE_MOBILE_DATA)
    check_only = "--check" in args
    serial = _serial()

    def default_route() -> str:
        return _first_line(_shell(serial, "ip", "route", "show", "default"))

    route = default_route()
    if check_only:
        log(f"default route: {route or 'none'}")
        return 0 if route else 1
    if route:
        log(f"the phone already has a default route ({route})")
        return 0

    log("enabling mobile data")
    if status(["adb", "-s", serial, "shell", "svc", "data", "enable"]) != 0:
        die("svc data enable failed")

    for _ in range(10):
        time.sleep(1)
        route = default_route()
        if route:
            log(f"mobile data is up ({route})")
            return 0
    die("mobile data was enabled but no default route appeared")
    return 1
