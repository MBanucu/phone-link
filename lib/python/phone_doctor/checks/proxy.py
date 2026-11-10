"""Proxy checks: ambulance APK, install, version, compatibility, request."""

from __future__ import annotations

import json
import re

from ..context import Context
from ..model import Result, fail, ok, skip, warn

SECTION = "[proxy]"

FDROID_URL = "https://f-droid.org/api/v1/packages/"


def _dump(ctx: Context) -> str:
    return ctx.adb("shell", "dumpsys package", ctx.proxy_pkg)


def _installed_versions(ctx: Context) -> tuple[str, str, str, str]:
    dump = _dump(ctx)

    def first(pattern: str) -> str:
        match = re.search(pattern, dump)
        return match.group(1) if match else ""

    return (
        first(r"versionName=(\S+)"),
        first(r"versionCode=(\d+)"),
        first(r"minSdk=(\d+)"),
        first(r"targetSdk=(\d+)"),
    )


def _fdroid_latest(ctx: Context) -> tuple[str, str]:
    raw = ctx.text(
        ["curl", "-fsSL", "--max-time", "10", FDROID_URL + ctx.proxy_pkg],
        timeout=10,
    )
    try:
        data = json.loads(raw)
    except (ValueError, TypeError):
        return "", ""
    code = str(data.get("suggestedVersionCode", ""))
    name = ""
    for package in data.get("packages", []):
        if str(package.get("versionCode")) == code:
            name = str(package.get("versionName", ""))
            break
    return code, name


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

    apk = ctx.apk_cached()
    if apk:
        results.append(ok("apk_cache", "ambulance apk", str(apk)))
    else:
        results.append(
            fail(
                "apk_cache",
                "ambulance apk",
                "none cached (run phone-fix-apk)",
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
            latest_code, latest_name = _fdroid_latest(ctx)
            if not latest_code:
                results.append(
                    skip(
                        "proxy_version",
                        "proxy version",
                        "F-Droid unreachable (offline?)",
                    )
                )
            elif code == latest_code:
                results.append(
                    ok(
                        "proxy_version",
                        "proxy version",
                        f"{version} ({code}), F-Droid latest",
                    )
                )
            else:
                results.append(
                    warn(
                        "proxy_version",
                        "proxy version",
                        f"{version} ({code}) < {latest_name or '?'} ({latest_code}); "
                        "run phone-proxy-install --fdroid",
                    )
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

    results.append(_proxy_request(ctx, ctx.target_ip))
    return results
