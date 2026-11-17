"""The proxy app's commands: start, stop and configure it over adb.

The app answers its own intents and prints what it is doing for
`dumpsys activity service`, so nothing here needs the screen, the keyguard or
uiautomator: a start is `am start-foreground-service START` with the
configuration as extras, a stop is `STOP`, and `--check` reads the dump.

The one thing that cannot be read back is the password — the app prints its
configuration but never a secret — so a setup verifies it the only way that
means anything: a request through the listener.
"""

from __future__ import annotations

import re
import sys
import time
import urllib.parse

from .. import phone, settings
from ..shell import capture, die, log, status

# The class keeps its package whatever id the app is installed under, the way
# the harness names it: only the package half of the component follows
# PHONE_PROXY_PKG.
CLASS = "org.phonelink.proxy"
SERVICE = f"{settings.PHONE_PROXY_PKG}/{CLASS}.ProxyService"
START = f"{CLASS}.action.START"
STOP = f"{CLASS}.action.STOP"

USAGE_START = """usage: phone-proxy-start [--check]

Starts the proxy app's listener over adb, then waits until the service says it
is listening. --check only reports whether it is running.
"""

USAGE_STOP = """usage: phone-proxy-stop [--check]

Stops the proxy app's listener over adb, then waits until the service is gone.
--check only reports whether it is running.
"""

USAGE_SETUP = """usage: phone-proxy-setup [--check] [--port N] [--user NAME] [--no-auto-start]

Starts the proxy on the given port with the credentials from the secrets file,
turns auto-start on unless --no-auto-start is given, and verifies a request
through the listener. --check only reports the current settings.
"""


def _installed(serial: str) -> bool:
    output = capture(
        ["adb", "-s", serial, "shell", "pm", "path", settings.PHONE_PROXY_PKG]
    )
    return any(line.startswith("package:") for line in output.splitlines())


def _dump(serial: str) -> str:
    return capture(
        ["adb", "-s", serial, "shell", "dumpsys", "activity", "service", SERVICE]
    )


def _field(dump: str, name: str) -> str:
    """The service's own line for `name`, from the block it prints last.

    The dump starts with the app's help text and ends with what it is doing, so
    the last match is the live answer rather than an example in the help.
    """
    matches = re.findall(rf"^[ \t]+{name}[ \t]+(.+)$", dump, re.M)
    return matches[-1].strip() if matches else ""


def _state(serial: str) -> str:
    return _field(_dump(serial), "state")


def _running(state: str) -> bool:
    return "listening on" in state


def _gated(state: str) -> bool:
    """The service is up and answering, but nothing is listening.

    That is the app's SSID gate: a proxy whose network is not this one stays
    running and waits, which is the difference between "off" and "not on this
    network" the app prints in the same line.
    """
    return bool(state) and not _running(state)


def _send(serial: str, action: str, *extras: str) -> None:
    status(
        [
            "adb",
            "-s",
            serial,
            "shell",
            "am",
            "start-foreground-service",
            "-n",
            SERVICE,
            "-a",
            action,
            *extras,
        ]
    )


def _wait(serial: str, wanted, seconds: int) -> str:
    """Poll the service's own view of itself until it agrees, or time runs out."""
    state = _state(serial)
    deadline = time.time() + seconds
    while not wanted(state) and time.time() < deadline:
        time.sleep(1)
        state = _state(serial)
    return state


def _check_flag(args: list[str], usage: str) -> bool:
    check_only = False
    for value in args:
        if value == "--check":
            check_only = True
        elif value in ("-h", "--help"):
            print(usage, end="", file=sys.stderr)
            sys.exit(0)
        else:
            print(usage, end="", file=sys.stderr)
            die(f"unknown argument: {value}")
    return check_only


def phone_proxy_start(args: list[str]) -> int:
    """Start the listener, or say whether it is listening."""
    check_only = _check_flag(args, USAGE_START)
    serial = phone.phone_serial()
    if not serial:
        die("no phone attached (see adb devices)")
    if not _installed(serial):
        die(f"{settings.PHONE_PROXY_PKG} is not installed; run phone-proxy-install first")

    state = _state(serial)
    if _running(state):
        log(f"proxy is already listening ({state})")
        return 0
    if check_only:
        log(f"proxy is not listening ({state or 'stopped'})")
        return 1

    log("starting the proxy over adb")
    _send(serial, START)
    # The gate is deterministic, so a "not listening" answer is the final word
    # rather than something to wait out.
    state = _wait(serial, lambda each: _running(each) or _gated(each), 15)
    if _running(state):
        log(f"proxy started ({state})")
        return 0
    if _gated(state):
        die(
            f"proxy is not listening: {state} — its SSID gate does not match "
            "this network, or it is waiting for one"
        )
    die(f"proxy did not start ({state or 'the service gave no state'})")
    return 1


def phone_proxy_stop(args: list[str]) -> int:
    """Stop the listener, or say whether it is running."""
    check_only = _check_flag(args, USAGE_STOP)
    serial = phone.phone_serial()
    if not serial:
        die("no phone attached (see adb devices)")
    if not _installed(serial):
        die(f"{settings.PHONE_PROXY_PKG} is not installed; run phone-proxy-install first")

    state = _state(serial)
    if not state:
        log("proxy is not running")
        return 0
    if check_only:
        log(f"proxy is running ({state})")
        return 1

    log("stopping the proxy over adb")
    _send(serial, STOP)
    state = _wait(serial, lambda each: not each, 5)
    if state:
        die(f"proxy did not stop ({state})")
    log("proxy stopped")
    return 0


def _request(address: str, port: str, user: str, password: str) -> str:
    """What one request through the listener answers."""
    credentials = urllib.parse.quote(user, safe="")
    secret = urllib.parse.quote(password, safe="")
    code = capture(
        [
            "curl",
            "-4",
            "-s",
            "-m",
            "20",
            "--socks5-hostname",
            f"{credentials}:{secret}@{address}:{port}",
            "-o",
            "/dev/null",
            "-w",
            "%{http_code}",
            "https://example.com",
        ],
        timeout=30,
    ).strip()
    return code or "000"


def _settings(dump: str) -> tuple[str, str, str]:
    """Port, user and auto-start as the service prints them."""
    using = _field(dump, "using")
    port = re.search(r"\bport (\d+)", using)
    user = re.search(r"\buser (\S+)", using)
    return (
        port.group(1) if port else "",
        user.group(1) if user else "",
        _field(dump, "auto-start"),
    )


def phone_proxy_setup(args: list[str]) -> int:
    """Start the proxy with the secrets file's credentials, and verify it."""
    port = str(settings.PHONE_PROXY_PORT)
    user = settings.PHONE_PROXY_USER
    auto_start = True
    check_only = False
    index = 0
    while index < len(args):
        value = args[index]
        if value == "--check":
            check_only = True
        elif value == "--port":
            if index + 1 >= len(args):
                die("--port needs a value")
            port = args[index + 1]
            index += 1
        elif value == "--user":
            if index + 1 >= len(args):
                die("--user needs a value")
            user = args[index + 1]
            index += 1
        elif value == "--no-auto-start":
            auto_start = False
        elif value in ("-h", "--help"):
            print(USAGE_SETUP, end="", file=sys.stderr)
            return 0
        else:
            print(USAGE_SETUP, end="", file=sys.stderr)
            die(f"unknown argument: {value}")
        index += 1

    if not port.isdigit():
        die(f"port must be numeric: {port}")
    if not 1 <= int(port) <= 65535:
        die(f"port out of range: {port}")
    if not user:
        die("username cannot be empty")

    password = phone.proxy_pass()
    if not password:
        die(
            "no PHONE_SOCKS_PASS in the secrets file (run with sudo, or set "
            "PHONE_SECRETS)"
        )

    serial = phone.phone_serial()
    if not serial:
        die("no phone attached (see adb devices)")
    if not _installed(serial):
        die(f"{settings.PHONE_PROXY_PKG} is not installed; run phone-proxy-install first")

    want_auto = "true" if auto_start else "false"

    if check_only:
        dump = _dump(serial)
        state = _field(dump, "state")
        current_port, current_user, current_auto = _settings(dump)
        running = _running(state)
        sys.stderr.write(f"port       {current_port or '?'} (want {port})\n")
        sys.stderr.write(f"username   {current_user or '<empty>'} (want {user})\n")
        sys.stderr.write(f"auto-start {current_auto or '?'} (want {want_auto})\n")
        sys.stderr.write(
            f"proxy      {'listening' if running else (state or 'stopped')} "
            "(want listening)\n"
        )
        verified = False
        if running:
            for address in phone.phone_ips(serial):
                verified = _request(address, port, user, password) == "200"
                if verified:
                    break
            sys.stderr.write(f"request    {'200' if verified else 'no'} (want 200)\n")
        good = (
            current_port == port
            and current_user == user
            and current_auto == want_auto
            and running
            and verified
        )
        return 0 if good else 1

    log(f"phone: {serial}")
    log(f"starting the proxy on port {port} as {user}")
    _send(
        serial,
        START,
        "--ei",
        "port",
        port,
        "--es",
        "user",
        user,
        "--es",
        "password",
        password,
        "--ez",
        "anonymous",
        "false",
        "--ez",
        "auto_start",
        want_auto,
    )

    state = _wait(serial, lambda each: _running(each) or _gated(each), 15)
    if not _running(state):
        if _gated(state):
            die(
                f"proxy is not listening: {state} — its SSID gate does not match "
                "this network"
            )
        die(f"proxy did not start ({state or 'the service gave no state'})")

    written_port, written_user, written_auto = _settings(_dump(serial))
    if written_port != port or written_user != user or written_auto != want_auto:
        die(
            "the app did not take the settings "
            f"(port {written_port}, user '{written_user}', "
            f"auto-start {written_auto})"
        )
    log(
        f"settings written: port {port}, user {user}, "
        f"password {len(password)} chars, auto-start {want_auto}"
    )

    verified = ""
    for address in phone.phone_ips(serial):
        code = _request(address, port, user, password)
        log(f"{address}:{port} -> https://example.com = {code}")
        if code == "200":
            verified = address
            break
    if not verified:
        die("the proxy is listening but no LAN address answered with 200")
    log(f"phone proxy configured and verified through {verified}")
    return 0
