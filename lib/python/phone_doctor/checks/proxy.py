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


def _tree_version(ctx: Context) -> tuple[str, str]:
    """The versionName and versionCode this checkout builds.

    The manifest is a template — `android/build.sh` stamps the version into a
    copy — so the number comes from `android/version`, the same file the build
    reads, and only a checkout without one falls back to the manifest.
    """
    version_file = ctx.proxy_manifest.parent / "version"
    try:
        text = version_file.read_text().strip()
    except OSError:
        text = ""
    if re.fullmatch(r"\d+\.\d+\.\d+", text):
        parts = [int(part) for part in text.split(".")]
        code = f"{parts[0]}{parts[1]:02d}{parts[2]:02d}"
        return text, code
    try:
        manifest = ctx.proxy_manifest.read_text()
    except OSError:
        return "", ""
    name = re.search(r'android:versionName="([^"]+)"', manifest)
    code = re.search(r'android:versionCode="(\d+)"', manifest)
    return (name.group(1) if name else ""), (code.group(1) if code else "")


def _version_tuple(text: str) -> tuple[int, ...]:
    numbers = [int(part) for part in re.findall(r"\d+", text)[:3]]
    return tuple(numbers)


def _latest_tag(ctx: Context) -> str:
    """The newest release tag, read once a day; "" when it cannot be read.

    The one check that asks a network question, because "is this release the
    newest" is not a fact the phone has. A cached answer lasts a day and a host
    that cannot reach GitHub says so instead of stalling: three seconds, once.
    """
    cache = os.path.join(
        os.environ.get("XDG_CACHE_HOME")
        or os.path.join(os.path.expanduser("~"), ".cache"),
        "phone-link",
        "latest-release",
    )
    tag = ""
    try:
        if time.time() - os.path.getmtime(cache) < 86400:
            with open(cache, encoding="utf-8") as handle:
                tag = handle.read().strip()
    except OSError:
        pass
    if tag:
        return tag
    repo = ctx.get("PHONE_LINK_REPO", "MBanucu/phone-link")
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
        latest = _latest_tag(ctx) if version else ""
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

    results.append(_proxy_request(ctx, ctx.target_ip))
    return results
