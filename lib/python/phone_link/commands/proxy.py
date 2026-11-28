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

import base64
import binascii
import json
import os
import re
import secrets
import socket
import sys
import tempfile
import time
import urllib.parse

from .. import boot, contract, phone, settings
from ..shell import capture, die, log, must, status
from .common import _only_help, _serial, _shell

# The class keeps its package whatever id the app is installed under, the way
# the harness names it: only the package half of the component follows
# PHONE_PROXY_PKG.
CLASS = "org.phonelink.proxy"
SERVICE = f"{settings.PHONE_PROXY_PKG}/{CLASS}.ProxyService"
STATE_FILE = f"/sdcard/Android/data/{settings.PHONE_PROXY_PKG}/files/state.txt"
SAVED_INDEX_VERSION = 1
START = f"{CLASS}.action.START"
STOP = f"{CLASS}.action.STOP"
EXPORT = f"{CLASS}.action.EXPORT"
IMPORT = f"{CLASS}.action.IMPORT"

# The one-shot transfer between the laptop and the app. The app owns the same
# numbers in ProfileTransfer.java; the README is the contract.
TRANSFER_MAGIC = "PLX1"
TRANSFER_MAX_BYTES = 1024 * 1024
TRANSFER_APP = "phone-link-proxy"

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
--list   print the phone's saved proxies and listeners as JSON, for the panel;
         `service` is running/gated/stopped, `contract` is the app's contract
         version (null when it does not say), and a stopped service uses the
         app's non-secret saved index when its dump has no saved lines
"""

USAGE_EXPORT = """usage: phone-proxy-export [--out FILE]

Pulls every saved proxy off the phone over adb: one loopback socket, one
one-shot token, the same ProfileDocument JSON the app's menu exports. The file
holds every proxy's password in clear text, so it is written mode 0600 beside
the secrets (PHONE_PROXY_BACKUP, default
/etc/nixos/phone-link-proxies.json) unless --out names another path.

The app exports only while the screen is on and the keyguard is not locked; a
locked or sleeping phone binds nothing
and this says so instead of waiting. The file is written after the whole
document has arrived, so a refused or interrupted transfer leaves no backup.
"""

USAGE_IMPORT = """usage: phone-proxy-import FILE

Puts a phone-proxy-export backup back into the app over the same one-shot
socket. The import replaces every saved proxy, like the menu's Import … replace,
and reports how many the app wrote. The app validates the whole document first,
so a malformed file changes nothing.
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


def _state_text(serial: str) -> str:
    """The app's own facts, readable while the service is stopped.

    A stopped service prints nothing for `dumpsys activity service`; the app
    still rewrites this file on every store change. Only the non-secret index
    is read from it here.
    """
    return capture(["adb", "-s", serial, "shell", "cat", STATE_FILE])


def _state_field(state_text: str, name: str) -> str:
    """One ``key value`` line from the app's non-secret ``state.txt``.

    The file is written as ``auto_start true``, without the indentation the
    service dump uses, so this cannot share `_field`. A missing line is an
    older app or one that has not run yet, never a failure.
    """
    for line in state_text.splitlines():
        key, _, value = line.partition(" ")
        if key.strip() == name:
            return value.strip()
    return ""


def _contract(serial: str, dump: str = "") -> int | None:
    """The app's contract version, from ``state.txt`` first and the dump second.

    The state file answers while the service is stopped, which is where a list
    or a setup check usually finds it; the dump is the fallback for a build that
    writes one but not the other. `dump` is the block a caller already read, so
    reading the version does not repeat that adb call.
    """
    version = contract.parse(_state_text(serial))
    if version is None:
        version = contract.parse(dump or _dump(serial))
    return version


def _warn_newer(version: int | None) -> None:
    """Name a newer app, then go on using the actions this laptop knows."""
    if version is None or contract.check(version) != contract.NEWER:
        return
    log(
        f"warning: the app speaks contract {version}; this laptop knows "
        f"contract {contract.KNOWN} — newer actions or extras may be ignored"
    )


def require_contract(serial: str, *, dump: str = "") -> int:
    """The app's contract version, refusing one too old for a transfer.

    EXPORT, IMPORT and a just-installed app need contract 1. An app without
    the line is contract 0, so the precise answer is to update the app rather
    than wait for a socket it will never open.
    """
    version = _contract(serial, dump)
    if contract.check(version) == contract.TOO_OLD:
        die(f"update the app to contract >= {contract.KNOWN}: run phone-proxy-install")
    _warn_newer(version)
    return version if version is not None else 0


def note_contract(serial: str) -> None:
    """Report the version after an install without failing the install.

    A fresh install, and an update from a build that predates the line, leave
    ``state.txt`` exactly as the previous app wrote it until the app runs and
    rewrites it. "No line yet" is therefore not proof that the APK just
    installed is old, and the install has already succeeded: say what the next
    transfer will do instead of reporting a failure for a stale file.
    """
    version = _contract(serial)
    if contract.check(version) == contract.TOO_OLD:
        log(
            "note: the installed app has not published contract "
            f">= {contract.KNOWN} yet; state.txt is rewritten when it runs, "
            "and export/import will ask for an update until then"
        )
        return
    _warn_newer(version)


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
        die(
            f"{settings.PHONE_PROXY_PKG} is not installed; run phone-proxy-install first"
        )

    dump = _dump(serial)
    _warn_newer(_contract(serial, dump))
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
        die(
            f"{settings.PHONE_PROXY_PKG} is not installed; run phone-proxy-install first"
        )

    dump = _dump(serial)
    _warn_newer(_contract(serial, dump))
    state = _field(dump, "state")
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
        die(
            f"{settings.PHONE_PROXY_PKG} is not installed; run phone-proxy-install first"
        )

    _warn_newer(_contract(serial))

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

    reachable = ""
    for address in phone.phone_ips(serial):
        code = _request(address, port, user, password)
        log(f"{address}:{port} -> https://example.com = {code}")
        if code == "200":
            reachable = address
            break
    if not reachable:
        die("the proxy is listening but no LAN address answered with 200")
    log(f"phone proxy configured and verified through {reachable}")
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


def _decode_field(value: str) -> str:
    """One Base64URL field from the app's saved-profile index.

    The app writes ``~`` for an empty field, standard padding included, so an
    unreadable field is treated as empty rather than ending the whole list: a
    name is a label, not a credential.
    """
    if value in ("", "~"):
        return ""
    try:
        raw = base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))
        return raw.decode("utf-8")
    except (binascii.Error, UnicodeDecodeError, ValueError):
        return ""


def _saved_index(state_text: str) -> list[dict]:
    """The non-secret saved-profile index the app writes to ``state.txt``.

    The service prints its saved list only while it runs; a stopped app still
    rewrites this file on every change. The format is documented in the app's
    README and ``SavedIndex.java``::

        saved_index_version 1
        saved_index_count 2
        saved_index <b64(name)> <port> <b64(user)> <anonymous> <auto_start> <b64(ssid)> <any_network>

    An unknown version or a file without the block is an older app, not an
    error: the caller then has no saved list, exactly as before.
    """
    version = ""
    count = None
    entries: list[dict] = []
    for line in state_text.splitlines():
        name, _, value = line.partition(" ")
        value = value.strip()
        if name == "saved_index_version":
            version = value
        elif name == "saved_index_count":
            try:
                count = int(value)
            except ValueError:
                count = None
        elif name == "saved_index":
            parts = line.split(" ")
            if len(parts) != 8 or parts[1] == "none":
                continue
            try:
                port = int(parts[2])
            except ValueError:
                continue
            entries.append(
                {
                    "name": _decode_field(parts[1]),
                    "port": port,
                    "user": _decode_field(parts[3]),
                    "anonymous": parts[4] == "1",
                    "auto_start": parts[5] == "1",
                    "ssid": _decode_field(parts[6]),
                    "any_network": parts[7] == "1",
                }
            )
    if version != str(SAVED_INDEX_VERSION):
        return []
    if count is not None and count != len(entries):
        # A torn write is possible in principle; the file is replaced
        # atomically, so a mismatch means an app this build does not know.
        return []
    return entries


def _service_status(dump: str) -> str:
    """`running`, `gated` or `stopped` from the service's own state line."""
    state = _field(dump, "state")
    if _running(state):
        return "running"
    if state:
        return "gated"
    return "stopped"


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


def _list_payload(serial: str, dump: str, contract_version: int | None) -> dict:
    running = _dump_listeners(dump)
    status = _service_status(dump)
    entries = _dump_saved(dump)
    if not entries and status == "stopped":
        # A stopped service prints no saved lines. The app's non-secret index
        # is the difference between "nothing is saved" and "nothing can be
        # read right now"; it is never a reason to start the service.
        entries = _saved_index(_state_text(serial))
    saved = []
    for entry in entries:
        offerable, why = _credentials_for(entry)
        # The same shape whether the list came from the dump or the index, so
        # a consumer does not have to care which one answered.
        saved.append(
            {
                "name": entry["name"],
                "port": entry["port"],
                "user": entry["user"],
                "anonymous": entry["anonymous"],
                "running": entry["port"] in running,
                "offerable": offerable,
                "why": why,
            }
        )
    return {
        "active": settings.active_port(),
        "port_source": _port_source(),
        "runtime_file": settings.PHONE_RUNTIME_PORT_FILE,
        "service": status,
        "contract": contract_version,
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
    contract_version = _contract(serial, dump)
    _warn_newer(contract_version)

    if parsed["list"]:
        print(json.dumps(_list_payload(serial, dump, contract_version), indent=2))
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
                f"({_field(dump, 'state') or 'no state'}); nothing was changed"
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


# -- past the app: export and import over a one-shot socket -----------------


def backup_writable(path: str | None = None) -> bool:
    """Whether this process may write the backup at `path` (default) now."""
    target = path or settings.PHONE_PROXY_BACKUP
    directory = os.path.dirname(os.path.abspath(target))
    return os.path.isdir(directory) and os.access(directory, os.W_OK)


def check_backup_path(path: str) -> None:
    """Refuse a backup the repository would stage: a password file in git.

    `/etc/nixos` is a git work tree on this machine, and the default backup
    sits beside the secrets there. The file is not ignored by that repository,
    so writing it would make every proxy password a `git add -A` away. A path
    outside a work tree, or one the repository ignores, is fine; no `git` means
    no repository to protect and is also fine.
    """
    target = os.path.abspath(path)
    directory = os.path.dirname(target)
    if not os.path.isdir(directory):
        return
    inside = capture(
        ["git", "-C", directory, "rev-parse", "--is-inside-work-tree"], timeout=10
    ).strip()
    if inside != "true":
        return
    if (
        status(["git", "-C", directory, "check-ignore", "-q", "--", target], timeout=10)
        == 0
    ):
        return
    die(
        "refusing to write the saved-proxy backup inside a git work tree: "
        f"{target} is not ignored. Add it to .gitignore, or set "
        "PHONE_PROXY_BACKUP/--out to a path outside the repository."
    )


def _read_line(sock: socket.socket, *, eof_ok: bool = False) -> str | None:
    """One protocol line, without its LF.

    `eof_ok` is for the first answer only: adb can accept a forwarded connection
    a moment before the app has bound and then close it, and that is a retry,
    not a refused transfer by the phone.
    """
    data = bytearray()
    while len(data) <= 512:
        chunk = sock.recv(1)
        if not chunk:
            if eof_ok and not data:
                return None
            die("the phone closed the transfer before answering")
        if chunk == b"\n":
            return data.decode("ascii", "replace").rstrip("\r")
        data += chunk
    die("the phone sent a transfer line that is too long")


def _read_exact(sock: socket.socket, length: int) -> bytes:
    body = bytearray()
    while len(body) < length:
        chunk = sock.recv(length - len(body))
        if not chunk:
            die("the phone closed the transfer in the middle of the document")
        body += chunk
    return bytes(body)


def _forward(serial: str, device_port: int) -> int:
    """Ask adb for a laptop port that reaches the app's loopback port."""
    output = capture(
        ["adb", "-s", serial, "forward", "tcp:0", f"tcp:{device_port}"], timeout=15
    )
    local = 0
    if output.strip().isdigit():
        local = int(output.strip())
    else:
        match = re.search(r"tcp:(\d+)\s+tcp:(\d+)", output)
        if match:
            local = int(match.group(1))
    if not 1 <= local <= 65535:
        die("adb forward did not give a laptop port to reach the transfer")
    return local


def _connect(serial: str, local: int, deadline: float) -> socket.socket:
    """Wait for the app's listener, then connect to it on loopback only."""
    while True:
        try:
            sock = socket.create_connection(("127.0.0.1", local), timeout=2)
            sock.settimeout(30)
            return sock
        except OSError:
            if time.time() >= deadline:
                die(
                    "the phone did not open the export/import socket: unlock the "
                    "phone and turn the screen on, then run the command again (an "
                    "app older than this command has no EXPORT/IMPORT and must be "
                    "updated first)"
                )
            time.sleep(0.05)


def _exchange(serial: str, action: str, body: bytes | None) -> tuple[int, bytes]:
    """Start the action, speak the transfer protocol once, and clean up."""
    device_port = 20000 + secrets.randbelow(40000)
    token = secrets.token_hex(16)
    _send(
        serial,
        action,
        "--ei",
        "port",
        str(device_port),
        "--es",
        "token",
        token,
    )
    deadline = time.time() + max(0.0, settings.PHONE_PROXY_TRANSFER_WAIT)
    local = 0
    sock: socket.socket | None = None
    try:
        while True:
            local = _forward(serial, device_port)
            sock = _connect(serial, local, deadline)
            sock.sendall(f"{TRANSFER_MAGIC} {token}\n".encode("ascii"))
            if body is not None:
                sock.sendall(f"PUT {len(body)}\n".encode("ascii") + body)
            header = _read_line(sock, eof_ok=True)
            if header is not None:
                break
            # adb took the connection before the app bound and closed it again.
            # The token has not been delivered, so one more forward is safe.
            sock.close()
            sock = None
            status(["adb", "-s", serial, "forward", "--remove", f"tcp:{local}"])
            local = 0
            if time.time() >= deadline:
                die(
                    "the phone did not open the export/import socket: unlock the "
                    "phone and turn the screen on, then run the command again (an "
                    "app older than this command has no EXPORT/IMPORT and must be "
                    "updated first)"
                )
            time.sleep(0.1)
        if header.startswith("ERR "):
            die(f"the phone refused the transfer: {header[4:]}")
        if not header.startswith("OK "):
            die("the phone answered the transfer with something unexpected")
        try:
            value = int(header[3:])
        except ValueError:
            die("the phone answered the transfer with a bad length")
        if body is None:
            if not 1 <= value <= TRANSFER_MAX_BYTES:
                die("the phone offered a backup larger than the transfer allows")
            return value, _read_exact(sock, value)
        return value, b""
    finally:
        if sock is not None:
            try:
                sock.close()
            except OSError:
                pass
        if local:
            status(["adb", "-s", serial, "forward", "--remove", f"tcp:{local}"])


def _document(body: bytes) -> dict:
    """The shape every caller relies on, so a wrong answer is never written."""
    if not 1 <= len(body) <= TRANSFER_MAX_BYTES:
        die("the backup is empty or larger than the transfer allows")
    try:
        document = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        die("the backup is not JSON")
    if not isinstance(document, dict) or document.get("app") != TRANSFER_APP:
        die("the backup is not a phone-link-proxy document")
    version = document.get("version", 1)
    if not isinstance(version, int) or version > 1:
        die("the backup is from a newer version of the app than this command reads")
    if not isinstance(document.get("saved", []), list):
        die("the backup has no list of saved proxies")
    return document


def _write_private(path: str, body: bytes) -> None:
    """Write a backup atomically and root-only, never through a wider mode."""
    target = os.path.abspath(path)
    directory = os.path.dirname(target)
    if not os.path.isdir(directory):
        die(f"no directory for the backup: {directory}")
    handle, temporary = tempfile.mkstemp(prefix=".phone-link-proxies.", dir=directory)
    try:
        os.fchmod(handle, 0o600)
        with os.fdopen(handle, "wb") as out:
            out.write(body)
        os.replace(temporary, target)
        os.chmod(target, 0o600)
    except BaseException:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise


def export_to(serial: str, path: str) -> dict:
    """Pull the app's saved proxies into `path`; return the parsed document."""
    check_backup_path(path)
    if not _installed(serial):
        die(f"{settings.PHONE_PROXY_PKG} is not installed; nothing to export")
    require_contract(serial)
    _, body = _exchange(serial, EXPORT, None)
    document = _document(body)
    _write_private(path, body)
    saved = document.get("saved", [])
    log(f"exported {len(saved)} saved proxies to {path} (mode 0600)")
    return document


def _read_file(path: str) -> bytes:
    try:
        size = os.path.getsize(path)
    except OSError:
        die(f"cannot read the backup: {path}")
    if not 1 <= size <= TRANSFER_MAX_BYTES:
        die(f"the backup is empty or larger than the transfer allows: {path}")
    try:
        with open(path, "rb") as handle:
            return handle.read()
    except OSError:
        die(f"cannot read the backup: {path}")


def import_from(serial: str, path: str, *, require: bool = True) -> int:
    """Write a backup into the app; return how many saved proxies it wrote.

    ``require=False`` is only for the restore after a replace-signer install:
    that install cleared the app's data, so ``state.txt`` cannot exist yet,
    while the backup in hand proves the previous app could export it.
    """
    if not _installed(serial):
        die(
            f"{settings.PHONE_PROXY_PKG} is not installed; run phone-proxy-install first"
        )
    if require:
        require_contract(serial)
    else:
        _warn_newer(_contract(serial))
    body = _read_file(path)
    _document(body)
    count, _ = _exchange(serial, IMPORT, body)
    log(f"imported {count} saved proxies from {path}")
    return count


def restore(serial: str, document: dict, path: str) -> None:
    """Import a backup, start the proxy that was in use, and verify its port."""
    count = import_from(serial, path, require=False)
    saved = [entry for entry in document.get("saved", []) if isinstance(entry, dict)]
    name = document.get("in_use") if isinstance(document.get("in_use"), str) else ""
    entry = next((one for one in saved if one.get("name") == name), None)
    if entry is None:
        # Nothing named as in use: the configuration in use is still worth
        # restoring, and a bare START resumes exactly that one.
        active = document.get("active")
        if isinstance(active, dict):
            entry = active
            name = ""
    if entry is None:
        log(
            f"imported {count} saved proxies; the backup names no proxy in use, "
            "so nothing was started"
        )
        return

    port = entry.get("port")
    if not isinstance(port, int) or not 1 <= port <= 65535:
        log(f"imported {count} saved proxies; the backup does not name their port")
        return

    if port not in _dump_listeners(_dump(serial)):
        if name:
            log(f'starting the imported proxy "{name}" on port {port}')
            _send(serial, START, "--es", "profile", name)
        else:
            log(f"starting the imported configuration on port {port}")
            _send(serial, START)
        state = _wait(
            serial,
            lambda state: _running(state) or _gated(state),
            int(settings.PHONE_PROXY_WAIT),
        )
        if _gated(state):
            log(
                f"imported {count} saved proxies; the proxy is waiting for its "
                f"network ({state}) and was not verified"
            )
            return
        if not _running(state):
            die(
                f"imported {count} saved proxies, but the proxy did not start "
                f"({state or 'no state'}); the backup is at {path}"
            )

    # The document the phone just sent back has the credentials, so the one
    # request that proves the restore does not need the laptop's own secret.
    anonymous = bool(entry.get("anonymous"))
    user = "" if anonymous else str(entry.get("user") or "")
    password = "" if anonymous else str(entry.get("password") or "")
    verified = ""
    for address in phone.phone_ips(serial):
        code = _request(address, str(port), user, password)
        log(f"{address}:{port} -> https://example.com = {code}")
        if code == "200":
            verified = address
            break
    if not verified:
        die(
            f"imported {count} saved proxies, but port {port} did not answer "
            f"with 200; the backup is at {path}"
        )
    log(
        f'imported {count} saved proxies and verified "{name or "the configuration"}" '
        f"on port {port} through {verified}"
    )


def _needs_root_to_write(path: str) -> bool:
    return not backup_writable(path)


def _needs_root_to_read(path: str) -> bool:
    return not os.access(path, os.R_OK)


def _export_args(args: list[str]) -> str:
    out = settings.PHONE_PROXY_BACKUP
    index = 0
    while index < len(args):
        value = args[index]
        if value == "--out":
            if index + 1 >= len(args):
                print(USAGE_EXPORT, end="", file=sys.stderr)
                die("--out needs a file")
            out = args[index + 1]
            index += 1
        elif value in ("-h", "--help"):
            print(USAGE_EXPORT, end="", file=sys.stderr)
            raise SystemExit(0)
        else:
            print(USAGE_EXPORT, end="", file=sys.stderr)
            die(f"unknown argument: {value}")
        index += 1
    return out


def phone_proxy_export(args: list[str]) -> int:
    """Pull every saved proxy off the phone into a root-only backup."""
    out = _export_args(args)
    check_backup_path(out)
    if _needs_root_to_write(out):
        phone.as_root("phone-proxy-export", args)
    serial = phone.phone_serial()
    if not serial:
        die("no phone attached (see adb devices)")
    export_to(serial, out)
    return 0


def phone_proxy_import(args: list[str]) -> int:
    """Write a phone-proxy-export backup back into the app."""
    path = ""
    for value in args:
        if value in ("-h", "--help"):
            print(USAGE_IMPORT, end="", file=sys.stderr)
            return 0
        if value.startswith("-"):
            print(USAGE_IMPORT, end="", file=sys.stderr)
            die(f"unknown argument: {value}")
        if path:
            print(USAGE_IMPORT, end="", file=sys.stderr)
            die("one backup file at a time")
        path = value
    if not path:
        print(USAGE_IMPORT, end="", file=sys.stderr)
        die("name the backup to import")
    if _needs_root_to_read(path):
        phone.as_root("phone-proxy-import", args)
    serial = phone.phone_serial()
    if not serial:
        die("no phone attached (see adb devices)")
    import_from(serial, path)
    return 0


USAGE_BATTERY = """usage: phone-proxy-battery-whitelist [--check]

Adds the proxy app to the device-idle (Doze) whitelist with
`cmd deviceidle whitelist +<package>`. --check only reports the state.
"""


def phone_proxy_battery_whitelist(args: list[str]) -> int:
    """Exempt the proxy app from battery optimisation (Doze)."""
    _only_help([value for value in args if value != "--check"], USAGE_BATTERY)
    check_only = "--check" in args
    serial = _serial()
    package = settings.PHONE_PROXY_PKG
    log(f"phone: {serial}")

    installed = _shell(serial, "pm", "path", package)
    if not any(line.startswith("package:") for line in installed.splitlines()):
        die(f"{package} is not installed; run phone-proxy-install first")

    def whitelisted() -> bool:
        return f",{package}," in _shell(serial, "dumpsys", "deviceidle", "whitelist")

    if whitelisted():
        log(f"{package}: already whitelisted from battery optimisation")
        return 0
    if check_only:
        log(f"{package}: not whitelisted (Doze may stop the proxy)")
        return 1

    output = capture(
        ["adb", "-s", serial, "shell", "cmd", "deviceidle", "whitelist", f"+{package}"]
    ).replace("\r", "")
    if not whitelisted():
        die(f"whitelisting failed: {output or 'no output'}")

    log(f"whitelisted {package} from battery optimisation")
    log("Doze will now leave the proxy service alone")
    return 0


USAGE_BOOT = """usage: phone-proxy-boot [--check]

Makes this repository's app come back by itself after a reboot: adds it to the
device-idle allowlist, grants the location and notification permissions a boot
start needs, and turns auto_start on (which also starts the proxy). It also
checks that the installed build can start before the first unlock: the
direct-boot flag and a receiver for LOCKED_BOOT_COMPLETED. --check only
reports, naming each missing input; a manifest fact needs a reinstall.

DokeOS Auto Start Management is the other boot gate. It is behind a signature
permission, so this command cannot read or write it: it names the screen and
reports the app's dated "likely blocked" fact without promising a restart.
"""


def phone_proxy_boot(args: list[str]) -> int:
    """Make the phone-link app survive a reboot."""
    _only_help([value for value in args if value != "--check"], USAGE_BOOT)
    check_only = "--check" in args
    serial = _serial()
    package = settings.PHONE_APP_PKG
    # The class keeps the app's own namespace: `.ProxyService` would be resolved
    # against the manifest package, which a renamed (test, vendored) build does
    # not share with the Java classes.
    service = f"{package}/{settings.PHONE_APP_NAMESPACE}.ProxyService"
    log(f"phone: {serial}")

    installed = _shell(serial, "pm", "path", package)
    if not any(line.startswith("package:") for line in installed.splitlines()):
        die(f"{package} is not installed; run phone-proxy-install first")

    def package_dump() -> str:
        return _shell(serial, "dumpsys", "package", package)

    def device_sdk() -> str:
        return _shell(serial, "getprop", "ro.build.version.sdk").strip()

    def whitelisted() -> bool:
        return f",{package}," in _shell(serial, "dumpsys", "deviceidle", "whitelist")

    def state_text() -> str:
        return _shell(
            serial,
            "cat",
            f"/sdcard/Android/data/{package}/files/state.txt",
        )

    def auto_start() -> str:
        # A stopped service prints nothing; the app's state file still answers,
        # the same fallback the doctor uses.
        text = _shell(serial, "dumpsys", "activity", "service", service)
        return boot.auto_start_state(text, state_text())

    def oem_note() -> None:
        # This is the gate adb cannot set: the list is behind a signature
        # permission, so say it is unknown instead of implying the reboot is
        # proven.
        log(
            "DokeOS Auto Start Management is not readable from adb; enable "
            '"Phone link proxy" there (System Manager > App Management > '
            "Auto Start Management)"
        )
        if boot.last_boot_missed(state_text()):
            log(
                "the app reports the last boot as likely blocked by DokeOS "
                "Auto Start Management; the same screen is where to enable it"
            )

    fixable, reinstall, unknown = boot.inspect(
        package_dump(), device_sdk(), auto_start(), whitelisted()
    )
    missing = fixable + reinstall

    if not missing and not unknown:
        log(f"{package}: every boot input adb can check is present")
        oem_note()
        log(
            "a reboot without unlocking is the only proof; with the DokeOS "
            "gate unreadable, this does not promise a restart"
        )
        return 0
    if check_only:
        for problem in missing + unknown:
            log(f"{package}: {problem}")
        if reinstall:
            log(f"{package}: reinstall the release; adb cannot add a manifest fact")
        return 1

    # Grants first, then the allowlist and auto_start, so the final read sees
    # the same state a boot would.
    for permission in boot.grants_needed(package_dump(), device_sdk()):
        status(
            [
                "adb",
                "-s",
                serial,
                "shell",
                "pm",
                "grant",
                package,
                f"android.permission.{permission}",
            ]
        )
    if not whitelisted():
        status(
            [
                "adb",
                "-s",
                serial,
                "shell",
                "cmd",
                "deviceidle",
                "whitelist",
                f"+{package}",
            ]
        )
    if auto_start() != "true":
        status(
            [
                "adb",
                "-s",
                serial,
                "shell",
                "am",
                "start-foreground-service",
                "-n",
                service,
                "-a",
                f"{package}.action.START",
                "--ez",
                "auto_start",
                "true",
            ]
        )
        # The app writes auto_start when it handles the intent; give it up to
        # ten seconds instead of trusting a fixed sleep.
        deadline = time.time() + 10
        while auto_start() != "true" and time.time() < deadline:
            time.sleep(1)

    fixable, reinstall, unknown = boot.inspect(
        package_dump(), device_sdk(), auto_start(), whitelisted()
    )
    if fixable or unknown:
        die("; ".join(fixable + unknown))
    if reinstall:
        die(
            f"{package}: this install cannot start before unlock: "
            + "; ".join(reinstall)
            + " (reinstall the release)"
        )
    log(f"{package}: every boot input adb can change is set")
    oem_note()
    log("a reboot without unlocking is the only proof")
    return 0
