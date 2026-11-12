"""Phone-side helpers: adb transports, addresses, secrets and proxy probes.

The same helpers lib/phone-net.sh provides for the bash scripts, so a command
that moves from one language to the other keeps the behaviour it had: one
serial for "any attached phone", one for a network transport, and the proxy
password read from the root-only secrets file with the same failure message.
"""

from __future__ import annotations

import glob
import os
import urllib.parse

from . import settings
from .shell import capture, die, log, status


def phone_serial() -> str | None:
    """Serial of any attached device, USB or network, or None."""
    for line in capture(["adb", "devices"]).splitlines():
        fields = line.split()
        if len(fields) >= 2 and fields[1] == "device":
            return fields[0]
    return None


def adb_transport() -> str | None:
    """Serial of a network (non-USB) adb transport, or None."""
    for line in capture(["adb", "devices"]).splitlines():
        fields = line.split()
        if len(fields) >= 2 and fields[1] == "device" and ":" in fields[0]:
            return fields[0]
    return None


def phone_ips(serial: str | None = None) -> list[str]:
    """Every non-loopback IPv4 address the phone currently owns."""
    serial = serial or phone_serial()
    if not serial:
        return []
    output = capture(["adb", "-s", serial, "shell", "ip -4 -o addr show 2>/dev/null"])
    addresses = []
    for line in output.replace("\r", "").splitlines():
        fields = line.split()
        if len(fields) < 4:
            continue
        address = fields[3].split("/")[0]
        if address and not address.startswith("127."):
            addresses.append(address)
    return addresses


def is_root() -> bool:
    """Whether we are root, read through `id -u` like the bash helper did.

    Going through the command keeps the check observable: a test that stubs
    `id` gets the same answer the scripts used to get, and nothing here
    depends on which interpreter started us.
    """
    return capture(["id", "-u"]) == "0"


def as_root(name: str, argv: list[str]) -> None:
    """Re-run this command through sudo, as the bash scripts' as_root did."""
    if is_root():
        return
    from . import actions

    # Re-run the script itself, not the module: the shim re-resolves the
    # package next to its own path, which survives sudo's environment reset.
    shim = actions.binary(actions.BY_ID[name])
    os.execvp("sudo", ["sudo", "--", shim, *argv])


def tcp_open(ip: str, seconds: int = 3, port: int | None = None) -> bool:
    """True while something accepts a connection on the proxy port.

    Probed with the same `timeout … /dev/tcp` the bash helper used: a bounded
    connect, no lingering socket, and the same observable behaviour when a
    wrapper stubs `timeout` to answer without a network.
    """
    return (
        status(
            [
                "timeout",
                str(seconds),
                "bash",
                "-c",
                f"exec 3<>/dev/tcp/{ip}/{port or settings.PHONE_PROXY_PORT}",
            ]
        )
        == 0
    )


def read_secrets() -> dict[str, str]:
    """PHONE_* values from the root-only environment file.

    Parsed rather than sourced: the file is KEY=VALUE, and running it through a
    shell would be the one place the Python command still executed it.
    """
    path = settings.PHONE_SECRETS
    if not os.access(path, os.R_OK):
        die(f"cannot read {path} (run with sudo)")
    values: dict[str, str] = {}
    try:
        text = open(path, encoding="utf-8").read()
    except OSError:
        die(f"cannot read {path} (run with sudo)")
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip().removeprefix("export ").strip()
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        if key:
            values[key] = value
    return values


def proxy_pass() -> str:
    """PHONE_SOCKS_PASS, or a fatal error naming the missing file/key."""
    secrets = read_secrets()
    if "PHONE_SOCKS_PASS" not in secrets:
        die(
            "PHONE_SOCKS_PASS missing in "
            f"{settings.PHONE_SECRETS}"
        )
    return secrets["PHONE_SOCKS_PASS"]


def ap_pass() -> str:
    """PHONE_AP_PASS from the environment, or from the root-only secrets file."""
    if os.environ.get("PHONE_AP_PASS"):
        return os.environ["PHONE_AP_PASS"]
    if not os.access(settings.PHONE_SECRETS, os.R_OK):
        die(
            f"cannot read {settings.PHONE_SECRETS} (run with sudo) or set "
            "PHONE_AP_PASS"
        )
    value = read_secrets().get("PHONE_AP_PASS", "")
    if not value:
        die(f"PHONE_AP_PASS missing in {settings.PHONE_SECRETS}")
    return value


def ap_declarative() -> bool:
    """True when phoneLink.ap declares the AP profile."""
    try:
        with open(settings.PHONE_AP_DECLARATIVE, encoding="utf-8") as handle:
            return handle.readline().rstrip("\n") == settings.PHONE_AP_CON
    except OSError:
        return False


def apk_cached() -> str | None:
    """Newest proxy APK in the ambulance box or a user cache, if any."""
    directories = [settings.PHONE_APK_CACHE]
    if os.environ.get("PHONE_APK_DIR"):
        directories.append(os.environ["PHONE_APK_DIR"])
    if os.environ.get("XDG_CACHE_HOME"):
        directories.append(os.path.join(os.environ["XDG_CACHE_HOME"], "phone-link"))
    elif os.environ.get("HOME"):
        directories.append(os.path.join(os.environ["HOME"], ".cache", "phone-link"))

    newest: str | None = None
    for directory in directories:
        if not directory or not os.path.isdir(directory):
            continue
        for path in glob.glob(os.path.join(directory, "*.apk")):
            if not os.path.isfile(path):
                continue
            if newest is None or os.path.getmtime(path) > os.path.getmtime(newest):
                newest = path
    return newest


def proxy_check(ip: str) -> bool:
    """True if https://example.com loads through the proxy on `ip`."""
    password = proxy_pass()
    if not tcp_open(ip, 3):
        log(f"{ip}:{settings.PHONE_PROXY_PORT} closed")
        return False
    credentials = urllib.parse.quote(settings.PHONE_PROXY_USER, safe="")
    secret = urllib.parse.quote(password, safe="")
    code = capture(
        [
            "curl",
            "-4",
            "-s",
            "-m",
            "20",
            "--socks5-hostname",
            f"{credentials}:{secret}@{ip}:{settings.PHONE_PROXY_PORT}",
            "-o",
            "/dev/null",
            "-w",
            "%{http_code}",
            "https://example.com",
        ],
        timeout=30,
    )
    log(
        f"{ip}:{settings.PHONE_PROXY_PORT} -> https://example.com = "
        f"{code or '000'}"
    )
    return code == "200"
