"""Proxy checks: the app on the phone, its version, compatibility, a request.

The app is a project of its own, so there is no build in this checkout to
measure the phone against: the newest release of the app's repository is what
a reinstall would fetch (`phone-proxy-install`), and the version on the phone
is reported as what it is. No store is in the loop.

What is asked of the phone is what the app answers for itself: `dumpsys
package` for what is installed, and a request through the listener for whether
it works.
"""

from __future__ import annotations

import os
import re
import time

from ..context import Context
from ..model import Result, fail, ok, skip, warn

SECTION = "[proxy]"


def _installed_versions(ctx: Context) -> tuple[str, str, str, str]:
    dump = ctx.adb("shell", "dumpsys package", ctx.proxy_pkg)

    def first(pattern: str) -> str:
        match = re.search(pattern, dump)
        return match.group(1) if match else ""

    return (
        first(r"versionName=(\S+)"),
        first(r"versionCode=(\d+)"),
        first(r"minSdk=(\d+)"),
        first(r"targetSdk=(\d+)"),
    )


def _version_tuple(text: str) -> tuple[int, ...]:
    numbers = [int(part) for part in re.findall(r"\d+", text)[:3]]
    return tuple(numbers)


def _latest_tag(ctx: Context, installed: str) -> str:
    """The newest release tag, read once a day; "" when it cannot be read.

    The one check that asks a network question, because "is this release the
    newest" is not a fact the phone has. A cached answer lasts a day and a host
    that cannot reach GitHub says so instead of stalling: three seconds, once.

    The cache is per repository: `PHONE_PROXY_REPO` can point at a fork or at
    the repository the app lived in before it had one, and an answer about one
    of those is not an answer about the other.
    """
    repo = ctx.get("PHONE_PROXY_REPO", "MBanucu/phone-link-proxy")
    cache = os.path.join(
        os.environ.get("XDG_CACHE_HOME")
        or os.path.join(os.path.expanduser("~"), ".cache"),
        "phone-link",
        "latest-release-" + repo.replace("/", "-"),
    )
    tag = ""
    try:
        if time.time() - os.path.getmtime(cache) < 86400:
            with open(cache, encoding="utf-8") as handle:
                tag = handle.read().strip()
    except OSError:
        pass
    # A cached tag that is not newer than what is installed is stale by
    # definition — a release landed since or the phone is ahead of this tree —
    # so it is worth one question rather than a day of a misleading answer.
    if tag and _version_tuple(tag) > _version_tuple(installed):
        return tag
    proc = ctx.run(
        [
            "curl",
            "-fsS",
            "--max-time",
            "3",
            f"https://api.github.com/repos/{repo}/releases/latest",
        ],
        timeout=5,
    )
    match = re.search(r'"tag_name"\s*:\s*"([^"]+)"', (proc.stdout or "") if proc else "")
    tag = match.group(1) if match else ""
    if tag:
        try:
            os.makedirs(os.path.dirname(cache), exist_ok=True)
            with open(cache, "w", encoding="utf-8") as handle:
                handle.write(tag + "\n")
        except OSError:
            pass
    return tag


def _listening_ports(ctx: Context) -> list[int]:
    """The ports the service's own dump says are listening.

    The app prints one `running` line per listener, named or not, so this is
    what the phone is actually bound to — not what its saved configuration
    would start, and not what the laptop hoped for.
    """
    dump = ctx.adb(
        "shell",
        "dumpsys",
        "activity",
        "service",
        f"{ctx.proxy_pkg}/org.phonelink.proxy.ProxyService",
    )
    ports: list[int] = []
    for line in dump.splitlines():
        match = re.match(r"^[ \t]+running[ \t]+.*?\bport (\d+)\b", line)
        if match and int(match.group(1)) not in ports:
            ports.append(int(match.group(1)))
    return ports


def _port_match(ctx: Context) -> Result:
    """The port the laptop uses has to be one the phone listens on.

    A mismatch is a warning, not a failure: `proxy_request` already fails when
    nothing answers, and this names the reason before the request does — the
    tunnel is pointed at a port the phone is not on.
    """
    laptop = ctx.proxy_port
    if not ctx.serial:
        return skip("proxy_port", "proxy port", "no adb")
    ports = _listening_ports(ctx)
    if not ports:
        return skip(
            "proxy_port", "proxy port", f"laptop {laptop}, the phone is listening on nothing"
        )
    listed = ", ".join(str(port) for port in ports)
    if laptop.isdigit() and int(laptop) in ports:
        return ok("proxy_port", "proxy port", f"laptop {laptop}, phone {listed}")
    return warn(
        "proxy_port",
        "proxy port",
        f"laptop {laptop}, phone listens on {listed} (run phone-proxy-switch)",
    )


def _proxy_request(ctx: Context, target: str) -> Result:
    password = ctx.proxy_pass()
    if not password:
        return fail(
            "proxy_request",
            "proxy request",
            "no PHONE_SOCKS_PASS (run with sudo)",
        )
    code = ctx.text(
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
            "--socks5-hostname",
            f"{ctx.proxy_user}:{password}@{target}:{ctx.proxy_port}",
            ctx.probe_url,
        ],
        timeout=20,
    ).strip()
    prefix = f"{target}:{ctx.proxy_port} ->"
    if code == "200":
        return ok("proxy_request", "proxy request", f"{prefix} 200")
    return fail("proxy_request", "proxy request", f"{prefix} {code or '000'}")


def check(ctx: Context) -> list[Result]:
    results: list[Result] = []

    apk = ctx.proxy_apk
    if apk and apk.is_file():
        results.append(ok("apk_cache", "app apk", str(apk)))
    elif apk:
        # An explicit file that is not there beats a silent fallback: it is the
        # one the repair would hand to adb.
        results.append(fail("apk_cache", "app apk", f"{apk} is not there"))
    else:
        results.append(
            fail(
                "apk_cache",
                "app apk",
                "not downloaded (phone-proxy-install --release)",
            )
        )

    serial = ctx.serial
    if serial:
        if "package:" in ctx.text(["adb", "-s", serial, "shell", "pm", "path", ctx.proxy_pkg]):
            results.append(ok("proxy_app", "proxy app", ctx.proxy_pkg))
        else:
            results.append(
                fail("proxy_app", "proxy app", f"{ctx.proxy_pkg} not installed")
            )
    else:
        results.append(skip("proxy_app", "proxy app", "no adb"))

    if serial:
        version, code, min_sdk, target_sdk = _installed_versions(ctx)
        phone_sdk = ctx.adb("shell", "getprop", "ro.build.version.sdk").strip()
        if not code:
            results.append(skip("proxy_version", "proxy version", "app not installed"))
        else:
            results.append(ok("proxy_version", "proxy version", f"{version} ({code})"))
        latest = _latest_tag(ctx, version) if version else ""
        if not version:
            pass
        elif not latest:
            results.append(
                skip("app_release", "newer release", "unknown (cannot reach GitHub)")
            )
        elif _version_tuple(latest) > _version_tuple(version):
            results.append(
                warn(
                    "app_release",
                    "newer release",
                    f"{latest} is out, installed {version}; "
                    "run phone-proxy-install --release",
                )
            )
        else:
            results.append(
                ok("app_release", "newer release", f"nothing newer than {latest}")
            )
        if min_sdk and phone_sdk:
            if int(min_sdk) <= int(phone_sdk):
                results.append(
                    ok(
                        "proxy_compat",
                        "proxy compat",
                        f"minSdk {min_sdk} <= phone SDK {phone_sdk} "
                        f"(targetSdk {target_sdk or '?'})",
                    )
                )
            else:
                results.append(
                    fail(
                        "proxy_compat",
                        "proxy compat",
                        f"minSdk {min_sdk} > phone SDK {phone_sdk}",
                    )
                )
    else:
        results.append(skip("proxy_version", "proxy version", "no adb"))

    results.append(_port_match(ctx))
    results.append(_proxy_request(ctx, ctx.target_ip))
    return results
