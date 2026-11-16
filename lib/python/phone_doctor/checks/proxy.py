"""Proxy checks: this repository's app, its version, compatibility, a request.

The phone's proxy is the app in `android/`, so the version it is measured
against is the one in this checkout's manifest — the file `android/build.sh`
builds from — and a reinstall is `phone-proxy-install`, which installs that
build. No store is in the loop: an app that is not this checkout's build is
simply out of date with it, and an offline host is no excuse for a check that
cannot say which version the tree would produce.

What is asked of the phone is what the app answers for itself: `dumpsys
package` for what is installed, and a request through the listener for whether
it works.
"""

from __future__ import annotations

import re

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


def _tree_version(ctx: Context) -> tuple[str, str]:
    """The versionName and versionCode this checkout builds."""
    try:
        text = ctx.proxy_manifest.read_text()
    except OSError:
        return "", ""
    name = re.search(r'android:versionName="([^"]+)"', text)
    code = re.search(r'android:versionCode="(\d+)"', text)
    return (name.group(1) if name else ""), (code.group(1) if code else "")


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
                "not built (nix develop .#android -c ./android/build.sh)",
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
        tree_name, tree_code = _tree_version(ctx)
        if not code:
            results.append(skip("proxy_version", "proxy version", "app not installed"))
        elif not tree_code:
            results.append(
                skip(
                    "proxy_version",
                    "proxy version",
                    f"{version} ({code}); no manifest here to compare with",
                )
            )
        elif code == tree_code:
            results.append(
                ok(
                    "proxy_version",
                    "proxy version",
                    f"{version} ({code}), this checkout's build",
                )
            )
        else:
            results.append(
                warn(
                    "proxy_version",
                    "proxy version",
                    f"{version} ({code}) is not this checkout's "
                    f"{tree_name or '?'} ({tree_code}); run phone-proxy-install",
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
