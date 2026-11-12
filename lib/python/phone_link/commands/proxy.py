"""The proxy app's screen-driven commands: start, stop and configure it.

The app is not debuggable and its service is not exported, so its own settings
screen is driven with uiautomator. Everything here needs the phone unlocked.
"""

from __future__ import annotations

import os
import re
import shutil
import sys
import tempfile
import time

from .. import phone, settings, ui
from ..shell import capture, die, log, must, run, status

USAGE_START = """usage: phone-proxy-start [--check]

Opens the proxy app and taps Start, then waits until it reports running.
--check only reports whether the proxy is running.
"""

USAGE_STOP = """usage: phone-proxy-stop [--check]

Opens the proxy app and taps Stop, then waits until it reports stopped.
--check only reports whether the proxy is running.
"""

USAGE_SETUP = """usage: phone-proxy-setup [--check] [--port N] [--user NAME] [--no-auto-start]

Sets the proxy port, username and password (from the secrets file), enables
"start after reboot" unless --no-auto-start is given, then starts the proxy
and verifies a request through it. --check only reports the current settings.
"""

FIELDS = 3


def _installed(serial: str) -> bool:
    output = capture(["adb", "-s", serial, "shell", "pm", "path", settings.PHONE_PROXY_PKG])
    return any(line.startswith("package:") for line in output.splitlines())


def _open_app(serial: str, path: str, *, unlock: str | None) -> bool:
    """Open the app and dump its hierarchy, retrying while the phone wakes."""
    ui.launch(serial)
    for _ in range(10):
        if ui.dump(serial, path):
            return True
        time.sleep(1)
        status(["adb", "-s", serial, "shell", "input", "keyevent", "KEYCODE_WAKEUP"])
        if unlock:
            run([unlock])
        ui.launch(serial)
    return False


def phone_proxy_start(args: list[str]) -> int:
    """Start the proxy by tapping the app's own Start button."""
    check_only = False
    for value in args:
        if value == "--check":
            check_only = True
        elif value in ("-h", "--help"):
            print(USAGE_START, end="", file=sys.stderr)
            return 0
        else:
            print(USAGE_START, end="", file=sys.stderr)
            die(f"unknown argument: {value}")

    serial = phone.phone_serial()
    if not serial:
        die("no phone attached (see adb devices)")
    if not _installed(serial):
        die(f"{settings.PHONE_PROXY_PKG} is not installed; run phone-proxy-install first")

    directory = tempfile.mkdtemp()
    try:
        path = os.path.join(directory, "ui.xml")
        if check_only and ui.keyguard(serial):
            die("phone is locked; run phone-unlock, then this again")

        unlock = None
        if not check_only:
            unlock = ui.unlock_bin()
            if not unlock:
                die("phone-unlock not found next to this script or in PATH")
            must([unlock])

        if not _open_app(serial, path, unlock=unlock):
            if check_only and ui.keyguard(serial):
                die("phone is locked; run phone-unlock, then this again")
            die("cannot read the app UI (unlock with phone-unlock and install the app)")

        if ui.button(path, "Stop Proxy Service"):
            log("proxy is already running")
            return 0
        if check_only:
            log("proxy is stopped")
            return 1

        start = ui.button(path, "Start 5G Proxy")
        if not start:
            die("cannot find the Start button in the app UI")
        log("tapping Start")
        status(["adb", "-s", serial, "shell", "input", "tap", str(start[0]), str(start[1])])

        line = ""
        for _ in range(25):
            time.sleep(1)
            if not ui.dump(serial, path):
                continue
            if ui.button(path, "Stop Proxy Service"):
                log("proxy started")
                return 0
            line = ui.status_line(path)
            if "Failed to Start" in line:
                die(f"proxy failed to start: {line}")
            found = ui.blocker(path)
            if found:
                status(
                    ["adb", "-s", serial, "shell", "input", "tap",
                     str(found[0]), str(found[1])]
                )
        die(f"proxy did not start (last status: {line or 'unknown'})")
        return 1
    finally:
        shutil.rmtree(directory, ignore_errors=True)


def phone_proxy_stop(args: list[str]) -> int:
    """Stop the proxy by tapping the app's own Stop button."""
    check_only = False
    for value in args:
        if value == "--check":
            check_only = True
        elif value in ("-h", "--help"):
            print(USAGE_STOP, end="", file=sys.stderr)
            return 0
        else:
            print(USAGE_STOP, end="", file=sys.stderr)
            die(f"unknown argument: {value}")

    serial = phone.phone_serial()
    if not serial:
        die("no phone attached (see adb devices)")
    if not _installed(serial):
        die(f"{settings.PHONE_PROXY_PKG} is not installed; run phone-proxy-install first")

    directory = tempfile.mkdtemp()
    try:
        path = os.path.join(directory, "ui.xml")
        if check_only and ui.keyguard(serial):
            die("phone is locked; run phone-unlock, then this again")

        unlock = None
        if not check_only:
            unlock = ui.unlock_bin()
            if not unlock:
                die("phone-unlock not found next to this script or in PATH")
            must([unlock])

        if not _open_app(serial, path, unlock=unlock):
            if check_only and ui.keyguard(serial):
                die("phone is locked; run phone-unlock, then this again")
            die("cannot read the app UI (unlock with phone-unlock and install the app)")

        stop = ui.button(path, "Stop Proxy Service")
        if not stop:
            log("proxy is not running")
            return 0
        if check_only:
            log("proxy is running")
            return 1

        log("tapping Stop")
        status(["adb", "-s", serial, "shell", "input", "tap", str(stop[0]), str(stop[1])])

        for _ in range(20):
            time.sleep(1)
            if not ui.dump(serial, path):
                continue
            if ui.button(path, "Start 5G Proxy"):
                log("proxy stopped")
                return 0
        die("proxy did not stop (still showing Stop)")
        return 1
    finally:
        shutil.rmtree(directory, ignore_errors=True)


class _State:
    """The app's settings screen, read field by field."""

    def __init__(self, path: str) -> None:
        edits: list[tuple[int, int, int, str]] = []
        checks: list[tuple[int, int, str, str]] = []
        buttons: list[tuple[int, int, str]] = []
        statuses: list[str] = []
        for css, text, x, y, node in ui.nodes(path):
            package = node.get("package") or ""
            if package == settings.PHONE_PROXY_PKG:
                if css == "EditText":
                    # uiautomator reports the hint of an empty field as its text.
                    if text == "Empty = auth disabled":
                        text = ""
                    edits.append((y, x, y, text))
                elif css == "CheckBox":
                    checks.append(
                        (x, y, "true" if node.get("checked") == "true" else "false", text)
                    )
                elif css == "TextView" and any(word in text for word in ui.STATUS_WORDS):
                    statuses.append(text)
            # Buttons from every package, so permission and battery dialogs are
            # visible too.
            if css == "Button":
                buttons.append((x, y, text))

        self.fields = sorted(edits)
        self.checkbox = next(
            (item for item in checks if "automatically" in item[3].lower()), None
        )
        self.button = next(
            (item for item in buttons if re.search("Start|Stop", item[2])), None
        )
        self.status = statuses[0] if statuses else ""
        self.running = bool(self.button and "Stop" in self.button[2])

    @property
    def valid(self) -> bool:
        return (
            len(self.fields) >= FIELDS
            and self.checkbox is not None
            and self.button is not None
        )

    def values(self) -> tuple[str, str, str]:
        return tuple(field[3] for field in self.fields[:FIELDS])  # type: ignore[return-value]


def _bullet_count(text: str) -> int:
    return text.count("\u2022")


def phone_proxy_setup(args: list[str]) -> int:
    """Write the port, credentials and auto-start through the app's screen."""
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
    # `adb shell input text` types these literally; anything exotic gets
    # mangled.
    if not re.fullmatch(r"[A-Za-z0-9._-]+", user):
        die(f"username must match [A-Za-z0-9._-]+: {user}")

    password = phone.proxy_pass()
    if not re.fullmatch(r"[A-Za-z0-9._-]+", password):
        die(
            "password must match [A-Za-z0-9._-]+ "
            "(adb input text cannot type it safely)"
        )

    serial = phone.phone_serial()
    if not serial:
        die("no phone attached (see adb devices)")
    if not _installed(serial):
        die(f"{settings.PHONE_PROXY_PKG} is not installed; run phone-proxy-install first")

    directory = tempfile.mkdtemp()
    try:
        path = os.path.join(directory, "ui.xml")

        unlock = None
        if not check_only:
            unlock = ui.unlock_bin()
            if not unlock:
                die("phone-unlock not found next to this script or in PATH")
            must([unlock])
            # Grant what the app would otherwise stop and ask for in a dialog:
            # the notification permission and the Doze exemption.
            status(
                [
                    "adb", "-s", serial, "shell", "pm", "grant",
                    settings.PHONE_PROXY_PKG,
                    "android.permission.POST_NOTIFICATIONS",
                ]
            )
            status(
                [
                    "adb", "-s", serial, "shell", "cmd", "deviceidle", "whitelist",
                    f"+{settings.PHONE_PROXY_PKG}",
                ]
            )

        # --check is read-only and does not unlock, so fail fast instead of
        # timing out on every dump of a keyguard-covered screen.
        if check_only and ui.keyguard(serial):
            die("phone is locked; run phone-unlock, then this again")

        state: _State | None = None

        def snapshot() -> bool:
            nonlocal state
            if not ui.dump(serial, path):
                return False
            state = _State(path)
            return state.valid

        def dismiss_blockers() -> bool:
            for _ in range(3):
                if not snapshot():
                    return False
                found = ui.blocker(path)
                if not found:
                    return False
                log("dismissing a dialog to continue")
                status(
                    ["adb", "-s", serial, "shell", "input", "tap",
                     str(found[0]), str(found[1])]
                )
                time.sleep(2)
            return True

        def recover_ui() -> None:
            status(
                ["adb", "-s", serial, "shell", "input", "keyevent", "KEYCODE_WAKEUP"]
            )
            if unlock:
                run([unlock])
            ui.launch(serial)
            time.sleep(1)

        ui.launch(serial)
        dismiss_blockers()
        loaded = False
        for _ in range(10):
            loaded = snapshot()
            if loaded:
                break
            time.sleep(1)
            dismiss_blockers()
            recover_ui()
        if not loaded or state is None:
            if check_only and ui.keyguard(serial):
                die("phone is locked; run phone-unlock, then this again")
            die("cannot read the app UI (unlock with phone-unlock and install the app)")

        current_port, current_user, current_pass = state.values()
        assert state.checkbox is not None and state.button is not None
        check_x, check_y, checked, _ = state.checkbox
        button_x, button_y, _ = state.button
        want_checked = "true" if auto_start else "false"

        if check_only:
            chars = _bullet_count(current_pass)
            sys.stderr.write(f"port       {current_port or '?'} (want {port})\n")
            sys.stderr.write(
                f"username   {current_user or '<empty>'} (want {user})\n"
            )
            sys.stderr.write(f"password   {chars} chars (want {len(password)})\n")
            sys.stderr.write(f"auto-start {checked} (want {want_checked})\n")
            sys.stderr.write(
                f"proxy      {'running' if state.running else 'stopped'} "
                "(want running)\n"
            )
            return (
                0
                if current_port == port
                and current_user == user
                and chars == len(password)
                and checked == want_checked
                and state.running
                else 1
            )

        # A changed port only takes effect on a restart; auth is applied live.
        if state.running and current_port != port:
            log(f"stopping the running proxy to apply port {port}")
            status(
                ["adb", "-s", serial, "shell", "input", "tap",
                 str(button_x), str(button_y)]
            )
            for _ in range(10):
                time.sleep(1)
                if not snapshot():
                    continue
                assert state.button is not None
                button_x, button_y, _ = state.button
                if not state.running:
                    break

        # Replacing a field: tap it, move to the end, delete a generous number
        # of characters, then type the value.
        keystrokes = ["KEYCODE_MOVE_END", *(["67"] * 64)]

        def set_field(field: tuple[int, int, int, str], value: str) -> None:
            _, x, y, _ = field
            status(["adb", "-s", serial, "shell", "input", "tap", str(x), str(y)])
            status(
                ["adb", "-s", serial, "shell", "input", "keyevent", *keystrokes]
            )
            status(["adb", "-s", serial, "shell", "input", "text", value])

        set_field(state.fields[0], port)
        set_field(state.fields[1], user)
        set_field(state.fields[2], password)

        # Hide the keyboard so the rest of the screen is addressable again.
        status(["adb", "-s", serial, "shell", "input", "keyevent", "KEYCODE_BACK"])
        time.sleep(1)
        if not snapshot():
            recover_ui()
            if not snapshot():
                die("lost the app UI after typing the settings")

        assert state.checkbox is not None and state.button is not None
        check_x, check_y, checked, _ = state.checkbox
        button_x, button_y, _ = state.button
        current_port, current_user, current_pass = state.values()

        if checked != want_checked:
            status(
                ["adb", "-s", serial, "shell", "input", "tap",
                 str(check_x), str(check_y)]
            )
            time.sleep(1)
            if not snapshot():
                die("lost the app UI after toggling auto-start")
            assert state.checkbox is not None and state.button is not None
            checked = state.checkbox[2]
            button_x, button_y, _ = state.button
            current_port, current_user, current_pass = state.values()

        chars = _bullet_count(current_pass)
        if (
            current_port != port
            or current_user != user
            or chars != len(password)
            or checked != want_checked
        ):
            die(
                "settings did not stick "
                f"(port {current_port}, user '{current_user}', {chars} password "
                f"chars, auto-start {checked})"
            )
        log(
            f"settings written: port {port}, user {user}, "
            f"password {len(password)} chars, auto-start {want_checked}"
        )

        def start_and_wait() -> None:
            status(
                ["adb", "-s", serial, "shell", "input", "tap",
                 str(button_x), str(button_y)]
            )
            for _ in range(25):
                time.sleep(1)
                if not snapshot():
                    if dismiss_blockers():
                        continue
                    recover_ui()
                    continue
                assert state.button is not None
                if state.running:
                    return
                if "Failed to Start" in state.status:
                    die(f"proxy failed to start: {state.status}")
                # "Continue Anyway" on the battery dialog starts the proxy by
                # itself.
                if dismiss_blockers():
                    continue
            die(f"proxy did not start (last status: {state.status or 'unknown'})")

        if state.running:
            log(f"proxy already running on port {port}")
        else:
            start_and_wait()

        verified = False
        for address in phone.phone_ips(serial):
            if phone.proxy_check(address):
                verified = True
        if not verified:
            die("the proxy is running but no LAN address answered with 200")
        log("phone proxy configured and verified")
        return 0
    finally:
        shutil.rmtree(directory, ignore_errors=True)
