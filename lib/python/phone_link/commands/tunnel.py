"""Forwarding and the tunnel: the two repairs and the foreground run.

`phone-fix-forwarding` and `phone-fix-tunnel` elevate only the one call that
needs it; `phone-tunnel-run` re-runs itself as root up front.
"""

from __future__ import annotations

import glob
import os
import re
import tempfile
import time

from .. import phone, settings
from ..shell import capture, die, log, status
from .common import _only_help, _root


USAGE_FORWARDING = """usage: phone-fix-forwarding [--check]

Enables net.ipv4.ip_forward for the running kernel. --check only reports.
"""

USAGE_TUNNEL = """usage: phone-fix-tunnel [--check]

Starts phone-tun.service (or restarts it when the 2022 route is missing) and
waits for the route. --check only reports.
"""


def phone_fix_forwarding(args: list[str]) -> int:
    """Turn on IPv4 forwarding, which AP mode and the tunnel need."""
    _only_help([value for value in args if value != "--check"], USAGE_FORWARDING)
    check_only = "--check" in args

    current = capture(["sysctl", "-n", "net.ipv4.ip_forward"])
    if check_only:
        log(f"ip_forward: {current or 'unknown'}")
        return 0 if current == "1" else 1
    if current == "1":
        log("IPv4 forwarding is already on")
        return 0

    log("enabling IPv4 forwarding")
    _root(["sysctl", "-w", "net.ipv4.ip_forward=1"])
    current = capture(["sysctl", "-n", "net.ipv4.ip_forward"])
    if current != "1":
        die(f"IPv4 forwarding is still {current or 'unknown'}")
    log("IPv4 forwarding is on (runtime only; set it in the NixOS config to persist)")
    return 0


def _route_present() -> bool:
    return any("2022" in line for line in capture(["ip", "rule", "show"]).splitlines())


def phone_fix_tunnel(args: list[str]) -> int:
    """Start or restart phone-tun and wait until its policy route is installed."""
    _only_help([value for value in args if value != "--check"], USAGE_TUNNEL)
    check_only = "--check" in args

    state = capture(["systemctl", "is-active", "phone-tun.service"])
    if check_only:
        log(
            f"phone-tun: {state or 'unknown'}, route: "
            f"{'present' if _route_present() else 'missing'}"
        )
        return 0 if state == "active" and _route_present() else 1
    if state == "active" and _route_present():
        log("phone-tun is already active with its route")
        return 0

    if state == "active":
        log("restarting phone-tun (route missing)")
        _root(["systemctl", "restart", "phone-tun.service"])
    else:
        log("starting phone-tun")
        _root(["systemctl", "start", "phone-tun.service"])

    for _ in range(10):
        if _route_present():
            log("phone-tun is active with its route")
            return 0
        time.sleep(1)
    die("phone-tun did not install its route")
    return 1


def phone_tunnel_run(args: list[str]) -> int:
    """Run the phone tunnel in the foreground from the config NixOS built."""
    phone.as_root("phone-tunnel-run", args)

    config = ""
    via_adb = False
    index = 0
    while index < len(args):
        value = args[index]
        if value == "--config":
            if index + 1 >= len(args):
                die("--config needs a value")
            config = args[index + 1]
            index += 2
            continue
        if value == "--via-adb":
            via_adb = True
        else:
            die(f"unknown argument: {value}")
        index += 1

    if not config:
        candidates = glob.glob("/nix/store/*-phone-tun.json")
        if candidates:
            config = max(candidates, key=os.path.getmtime)
        if not config:
            die("no built phone-tun.json; build the configuration first")

    sing_box = ""
    try:
        with open("/etc/systemd/system/phone-tun.service", encoding="utf-8") as unit:
            for line in unit:
                match = re.match(r"^ExecStart=(\S*sing-box) run", line)
                if match:
                    sing_box = match.group(1)
                    break
    except OSError:
        pass
    if not sing_box:
        import shutil

        sing_box = shutil.which("sing-box") or ""
    if not sing_box or not os.access(sing_box, os.X_OK):
        die("sing-box binary not found")

    with open(config, encoding="utf-8") as handle:
        text = handle.read()
    password = phone.read_secrets().get("PHONE_SOCKS_PASS", "")
    if not password:
        die(f"PHONE_SOCKS_PASS missing in {settings.PHONE_SECRETS}")

    # The store config carries the module's default port; the one in use can be
    # another (`phone-proxy-switch`), so it is filled in here the same way the
    # unit's ExecStartPre does.
    port = str(settings.active_port())
    rewritten = text.replace("@PHONE_SOCKS_PASS@", password).replace(
        "@PHONE_SOCKS_PORT@", port
    )
    # A config built before the placeholder existed still has a number.
    rewritten = re.sub(r'"server_port":\s*\d+', f'"server_port": {port}', rewritten)

    fd, temporary = tempfile.mkstemp(prefix="phone-tun.", suffix=".json", dir="/run")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as out:
            out.write(rewritten)
        os.chmod(temporary, 0o600)

        if via_adb:
            serial = phone.phone_serial()
            if not serial:
                die("no phone attached (see adb devices)")
            if (
                status(["adb", "-s", serial, "reverse", f"tcp:{port}", f"tcp:{port}"])
                != 0
            ):
                die("adb reverse failed (is adb connected?)")
            with open(temporary, encoding="utf-8") as source:
                rewritten = source.read()
            rewritten = re.sub(r'"server": "[^"]*"', '"server": "127.0.0.1"', rewritten)
            with open(temporary, "w", encoding="utf-8") as out:
                out.write(rewritten)
            log(f"tunnel upstream: 127.0.0.1:{port} (adb reverse)")

        log(f"sing-box config: {temporary}")
        log("press Ctrl-C to stop; the TUN and its routes go away with it")
        os.execv(sing_box, [sing_box, "run", "-c", temporary])
    finally:
        try:
            os.unlink(temporary)
        except OSError:
            pass
    return 0
