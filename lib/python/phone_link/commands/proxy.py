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

import json
import os
import re
import sys
import tempfile
import time
import urllib.parse

from .. import phone, settings
from ..shell import capture, die, log, must, status

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
                         [--max-connections N]

Starts the proxy on the given port with the credentials from the secrets file,
turns auto-start on unless --no-auto-start is given, and verifies a request
through the listener. --check only reports the current settings.

--max-connections sets how many SOCKS connections the listener may keep open at
once, 16..1024. Left out, the app keeps its saved value — 256 on a fresh
install — and an app too old to know the setting ignores it.
"""

USAGE_SWITCH = """usage: phone-proxy-switch [--check | --list] (--port N | --profile NAME)

Makes the laptop use a port the phone is listening on. The phone is asked
first: --profile starts that saved proxy when it is not running, and --port
requires the phone to be listening there already. A request through the new
port has to answer with 200 before anything on the laptop changes; a switch
that cannot get that answer stops what it started and leaves the laptop alone.

Once it answers, the port is written to /run/phone-link/proxy-port — the
default of phoneLink.proxyPort, so no rebuild — and phone-tun and the relay are
restarted if they were running. The phone's listener on the old port is stopped
last, once the new one has answered.

--check  report the laptop's port and the phone's listeners; exit 1 when the
         phone does not listen on the port the laptop uses
--list   print the phone's saved proxies and listeners as JSON, for the panel
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

    dump = _dump(serial)
    state = _field(dump, "state")
    if _running(state):
        log(f"proxy is already listening ({state})")
        return 0
    if check_only:
        log(f"proxy is not listening ({state or 'stopped'})")
        return 1
    if not _dump_saved(dump):
        # A fresh install has nothing to start: the bare START asks the app to
        # resume a saved proxy, and with none it answers with no state at all.
        # Point at the command that creates one instead of reporting a failure
        # that reads like a broken app.
        die(
            "the app has no saved proxy configuration to start; run "
            "phone-proxy-setup first (or phone-proxy-install, then setup)"
        )

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
    """What one request through the listener answers.

    An empty user means the listener answers without authentication, which an
    anonymous saved proxy does: the credentials are left off rather than sent
    as empty ones.
    """
    proxy = f"{address}:{port}"
    if user or password:
        credentials = urllib.parse.quote(user, safe="")
        secret = urllib.parse.quote(password, safe="")
        proxy = f"{credentials}:{secret}@{proxy}"
    code = capture(
        [
            "curl",
            "-4",
            "-s",
            "-m",
            "20",
            "--socks5-hostname",
            proxy,
            "-o",
            "/dev/null",
            "-w",
            "%{http_code}",
            "https://example.com",
        ],
        timeout=30,
    ).strip()
    return code or "000"


def _settings(dump: str) -> tuple[str, str, str, str]:
    """Port, user, auto-start and connection ceiling as the service prints them.

    The ceiling has its own line (`max_connections 512`), which only the app
    builds that know the setting print; an older app leaves it empty.
    """
    using = _field(dump, "using")
    port = re.search(r"\bport (\d+)", using)
    user = re.search(r"\buser (\S+)", using)
    ceiling = re.search(r"\b(\d+)\b", _field(dump, "max_connections"))
    return (
        port.group(1) if port else "",
        user.group(1) if user else "",
        _field(dump, "auto-start"),
        ceiling.group(1) if ceiling else "",
    )


def phone_proxy_setup(args: list[str]) -> int:
    """Start the proxy with the secrets file's credentials, and verify it."""
    # No --port means the port the laptop is using, not the built-in default:
    # after a switch, a setup configures the one in use.
    port = str(settings.active_port())
    user = settings.PHONE_PROXY_USER
    auto_start = True
    max_connections: str | None = None
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
        elif value == "--max-connections":
            if index + 1 >= len(args):
                die("--max-connections needs a value")
            max_connections = args[index + 1]
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
    if max_connections is not None:
        if not max_connections.isdigit():
            die(f"max_connections must be numeric: {max_connections}")
        if not 16 <= int(max_connections) <= 1024:
            die(f"max_connections must be 16..1024, got {max_connections}")
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
        current_port, current_user, current_auto, current_max = _settings(dump)
        running = _running(state)
        sys.stderr.write(f"port       {current_port or '?'} (want {port})\n")
        sys.stderr.write(f"username   {current_user or '<empty>'} (want {user})\n")
        sys.stderr.write(f"auto-start {current_auto or '?'} (want {want_auto})\n")
        # An app build that does not know the setting prints no line; the
        # value is informational unless a ceiling was asked for.
        want_max = f" (want {max_connections})" if max_connections is not None else ""
        sys.stderr.write(f"max-connections {current_max or '<unknown>'}{want_max}\n")
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
            and (max_connections is None or current_max == max_connections)
            and running
            and verified
        )
        return 0 if good else 1

    log(f"phone: {serial}")
    log(f"starting the proxy on port {port} as {user}")
    extras = [
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
    ]
    if max_connections is not None:
        extras += ["--ei", "max_connections", max_connections]
    _send(serial, START, *extras)

    state = _wait(serial, lambda each: _running(each) or _gated(each), 15)
    if not _running(state):
        if _gated(state):
            die(
                f"proxy is not listening: {state} — its SSID gate does not match "
                "this network"
            )
        die(f"proxy did not start ({state or 'the service gave no state'})")

    written_port, written_user, written_auto, written_max = _settings(_dump(serial))
    if written_port != port or written_user != user or written_auto != want_auto:
        die(
            "the app did not take the settings "
            f"(port {written_port}, user '{written_user}', "
            f"auto-start {written_auto})"
        )
    if max_connections is not None and written_max and written_max != max_connections:
        die(
            "the app did not take max-connections "
            f"(want {max_connections}, got {written_max})"
        )
    if max_connections is not None and not written_max:
        # An older build ignores the extra and prints no line; the setup still
        # worked, so say which part was not applied instead of failing it.
        log("the app did not report max-connections (older build; extra ignored)")
    written = (
        f"settings written: port {port}, user {user}, "
        f"password {len(password)} chars, auto-start {want_auto}"
    )
    if max_connections is not None and written_max:
        written += f", max-connections {written_max}"
    log(written)

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


def _dump_listeners(dump: str) -> list[int]:
    """The ports the service says it is listening on right now.

    The dump prints one `running` line per port, named or not, so this is the
    phone's own answer rather than anything inferred from a request.
    """
    ports: list[int] = []
    for line in dump.splitlines():
        match = re.match(r"^[ \t]+running[ \t]+.*?\bport (\d+)\b", line)
        if not match:
            continue
        port = int(match.group(1))
        if port not in ports:
            ports.append(port)
    return ports


def _dump_saved(dump: str) -> list[dict]:
    """The saved proxies the service lists, minus the thing it never prints.

    A line reads `saved       "name" — port 1081 · SSID PhoneLink · user proxy
    · auto-start on · wireless debugging off`, so there is no password to pick
    up — which is the point: the laptop either has one of its own or it does
    not, and this command never learns the phone's.
    """
    saved: list[dict] = []
    for line in dump.splitlines():
        match = re.match(r'^[ \t]+saved[ \t]+"([^"]+)" \u2014 (.+)$', line)
        if not match:
            continue
        name, rest = match.group(1), match.group(2).split(" · auto-start")[0]
        port = re.search(r"\bport (\d+)", rest)
        user = re.search(r"\buser (\S+)", rest)
        saved.append(
            {
                "name": name,
                "port": int(port.group(1)) if port else 0,
                "user": user.group(1) if user else "",
                "anonymous": "no authentication" in rest,
            }
        )
    return saved


def _credentials_for(entry: dict) -> tuple[bool, str]:
    """Whether the laptop can authenticate to a saved proxy, and why not.

    adb never prints a proxy's password, so the only one the laptop can offer
    is its own `PHONE_SOCKS_PASS`. A saved proxy with another user is refused
    before it is started instead of after: the switch names the user it would
    need and leaves both ends alone.
    """
    if entry["anonymous"]:
        return True, ""
    if entry["user"] == settings.PHONE_PROXY_USER:
        return True, ""
    known = settings.PHONE_PROXY_USER
    return False, (
        f"it uses user {entry['user'] or '—'} and the laptop has a password for "
        f"user {known} only; adb never prints a saved proxy's password"
    )


def _port_source() -> str:
    """Where the port in use came from, so the report does not guess."""
    if os.environ.get("PHONE_PROXY_PORT"):
        return "PHONE_PROXY_PORT"
    if os.path.exists(settings.PHONE_RUNTIME_PORT_FILE):
        return settings.PHONE_RUNTIME_PORT_FILE
    return "the module's default"


def _list_payload(serial: str) -> dict:
    dump = _dump(serial)
    running = _dump_listeners(dump)
    saved = []
    for entry in _dump_saved(dump):
        offerable, why = _credentials_for(entry)
        entry.update(
            running=entry["port"] in running,
            offerable=offerable,
            why=why,
        )
        saved.append(entry)
    return {
        "active": settings.active_port(),
        "port_source": _port_source(),
        "runtime_file": settings.PHONE_RUNTIME_PORT_FILE,
        "running": running,
        "saved": saved,
    }


def _write_port(port: int) -> None:
    """Publish the port in use atomically, so a probe never reads half a file."""
    path = settings.PHONE_RUNTIME_PORT_FILE
    directory = os.path.dirname(path) or "."
    os.makedirs(directory, exist_ok=True)
    handle, temporary = tempfile.mkstemp(prefix="proxy-port.", dir=directory)
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as out:
            out.write(f"{port}\n")
        os.chmod(temporary, 0o644)
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise


def _wait_ports(serial: str, wanted, seconds: float) -> str:
    """Poll the service's `running` lines until they agree, or time runs out."""
    dump = _dump(serial)
    deadline = time.time() + seconds
    while not wanted(_dump_listeners(dump)) and time.time() < deadline:
        time.sleep(1)
        dump = _dump(serial)
    return dump


def _unit_active(name: str) -> bool:
    return capture(["systemctl", "is-active", name]).strip() == "active"


def _switch_args(args: list[str]) -> dict:
    parsed = {"port": "", "profile": "", "check": False, "list": False}
    index = 0
    while index < len(args):
        value = args[index]
        if value == "--check":
            parsed["check"] = True
        elif value == "--list":
            parsed["list"] = True
        elif value in ("--port", "--profile"):
            if index + 1 >= len(args):
                print(USAGE_SWITCH, end="", file=sys.stderr)
                die(f"{value} needs a value")
            key = "port" if value == "--port" else "profile"
            parsed[key] = args[index + 1]
            index += 1
        elif value in ("-h", "--help"):
            print(USAGE_SWITCH, end="", file=sys.stderr)
            raise SystemExit(0)
        else:
            print(USAGE_SWITCH, end="", file=sys.stderr)
            die(f"unknown argument: {value}")
        index += 1
    return parsed


def _target(parsed: dict, saved: list[dict]) -> tuple[int, str]:
    """The port to use and the user the laptop will authenticate as."""
    profile = parsed["profile"]
    if profile:
        entry = next((each for each in saved if each["name"] == profile), None)
        if entry is None:
            names = ", ".join(f'"{each["name"]}"' for each in saved) or "none"
            die(f'no saved proxy called "{profile}" on the phone (saved: {names})')
        if not entry["port"]:
            die(f'the app does not say which port "{profile}" listens on')
        offerable, why = _credentials_for(entry)
        if not offerable:
            die(f'cannot switch to "{profile}": {why}')
        return entry["port"], "" if entry["anonymous"] else entry["user"]

    port = parsed["port"]
    if not port:
        print(USAGE_SWITCH, end="", file=sys.stderr)
        die("choose a port with --port N or a saved proxy with --profile NAME")
    if not port.isdigit() or not 1 <= int(port) <= 65535:
        die(f"port out of range: {port}")
    return int(port), settings.PHONE_PROXY_USER


def phone_proxy_switch(args: list[str]) -> int:
    """Make the port the phone listens on the one the laptop uses."""
    parsed = _switch_args(args)
    # Writing the runtime port and restarting a unit is root's work; a check
    # and a list stay usable as the user who runs the panel.
    if not (parsed["check"] or parsed["list"]):
        phone.as_root("phone-proxy-switch", args)

    serial = phone.phone_serial()
    if not serial:
        die("no phone attached (see adb devices)")
    dump = _dump(serial)

    if parsed["list"]:
        print(json.dumps(_list_payload(serial), indent=2))
        return 0

    active = settings.active_port()
    listening = _dump_listeners(dump)
    if parsed["check"]:
        log(f"laptop port {active} ({_port_source()})")
        log(
            "phone ports  "
            + (", ".join(str(port) for port in listening) or "none (not listening)")
        )
        if active in listening:
            log("ok: the phone listens on the port the laptop uses")
            return 0
        log(
            "the laptop and the phone disagree; run phone-proxy-switch "
            "--port N or --profile NAME"
        )
        return 1

    saved = _dump_saved(dump)
    target, user = _target(parsed, saved)
    if target == active and target in listening:
        log(f"port {target} is already the one in use")
        return 0
    if target not in listening and not parsed["profile"]:
        die(
            f"the phone is not listening on port {target}; nothing was changed "
            f"(start one with phone-proxy-setup --port {target}, or name a saved "
            "proxy with --profile)"
        )

    password = phone.proxy_pass()
    started = False
    if target not in listening:
        profile = parsed["profile"]
        log(f'starting the saved proxy "{profile}" on port {target}')
        _send(serial, START, "--es", "profile", profile)
        dump = _wait_ports(
            serial, lambda ports: target in ports, settings.PHONE_PROXY_WAIT
        )
        if target not in _dump_listeners(dump):
            # The port is there but closed (its SSID gate), or the start failed
            # outright: stop what this switch created so the phone is left as
            # it was found, and keep the laptop where it was.
            _send(serial, STOP, "--ei", "port", str(target))
            die(
                f'the phone could not start "{profile}" on port {target} '
                f'({_field(dump, "state") or "no state"}); nothing was changed'
            )
        started = True

    address = ""
    for candidate in phone.phone_ips(serial):
        code = _request(candidate, str(target), user, password)
        log(f"{candidate}:{target} -> https://example.com = {code}")
        if code == "200":
            address = candidate
            break
    if not address:
        if started:
            log("the started proxy refuses the laptop's credentials; stopping it again")
            _send(serial, STOP, "--ei", "port", str(target))
            _wait_ports(
                serial,
                lambda ports: target not in ports,
                settings.PHONE_PROXY_SETTLE,
            )
        die(
            f"the phone did not answer through port {target} with the laptop's "
            "credentials; nothing was changed"
        )
    log(f"port {target} answered through {address}")

    _write_port(target)
    restarted = []
    for unit, label in (
        ("phone-tun.service", "phone-tun"),
        ("phone-socks-relay.service", "the relay"),
    ):
        if not _unit_active(unit):
            continue
        log(f"restarting {label} for port {target}")
        must(["systemctl", "restart", unit])
        restarted.append(label)
    if restarted:
        log("restarted " + " and ".join(restarted) + f" on port {target}")
    else:
        log(
            "nothing was running on the laptop; the timer starts the tunnel "
            "when the proxy answers"
        )

    if target != active and active in _dump_listeners(_dump(serial)):
        log(f"stopping the phone's listener on the old port {active}")
        _send(serial, STOP, "--ei", "port", str(active))
        dump = _wait_ports(
            serial, lambda ports: active not in ports, settings.PHONE_PROXY_SETTLE
        )
        if active in _dump_listeners(dump):
            log(f"the phone still lists port {active}")
    log(f"the laptop uses port {target} now ({settings.PHONE_RUNTIME_PORT_FILE})")
    return 0
