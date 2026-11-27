"""The adb-only commands: phone settings, proxy app and adb over Wi-Fi.

These actions change only the phone and need no root. Every adb call is pinned
to one serial, because two transports (USB and Wi-Fi) are normal here and a
bare `adb` refuses to choose between them.
"""

from __future__ import annotations

import hashlib
import os
import re
import sys
import time

from .. import boot, phone, settings
from ..shell import capture, die, have, log, run_both, run_text, status


USAGE_MOBILE_DATA = """usage: phone-fix-mobile-data [--check]

Enables mobile data with `svc data enable` and waits for a default route.
--check only reports the route.
"""

USAGE_WIFI_ENABLE = """usage: phone-wifi-enable [--check]

Turns Wi-Fi on and waits until Android reports it enabled. --check reports
without changing anything.
"""

USAGE_WIFI_FORGET = """usage: phone-wifi-forget [SSID] [--check] [--yes]

Removes the saved network, so a later connect starts from clean credentials.
--check only reports whether the SSID is saved. --yes skips the prompt.
"""

USAGE_TETHER_DEFAULT = """usage: phone-usb-tether-default [--check]

Makes USB tethering (RNDIS) the default USB action while keeping adb. --check
only reports whether it is already the default.
"""

USAGE_BATTERY = """usage: phone-proxy-battery-whitelist [--check]

Adds the proxy app to the device-idle (Doze) whitelist with
`cmd deviceidle whitelist +<package>`. --check only reports the state.
"""

USAGE_DATA_CLEAR = """usage: phone-proxy-data-clear [--yes] [--check]

Deletes the proxy app's data over adb (pm clear). Without --yes it asks first
and refuses in a non-interactive shell. --check only reports what would run.
"""

USAGE_UNINSTALL = """usage: phone-proxy-uninstall [--yes] [--keep-data] [--check]

Uninstalls the phone's SOCKS proxy app over adb. Without --yes it asks first,
and refuses in a non-interactive shell. --check only reports what would go.
"""

USAGE_INSTALL = """usage: phone-proxy-install [APK...]
       phone-proxy-install --fdroid [--check]
       phone-proxy-install --release [TAG]
       phone-proxy-install --pull [DIR]
       phone-proxy-install --status
       phone-proxy-install --check APK

Installs or updates the phone's SOCKS proxy app over adb (-r -g) — with no
argument, the newest release of the app's own repository
(MBanucu/phone-link-proxy, PHONE_PROXY_REPO to override) — pulls the installed
APK off the phone for later reinstalls, or reports what is installed. --fdroid
fetches the vendored proxy from F-Droid instead, for a phone that still runs
it; --release takes the latest release, or the one named by the tag given, and
checks the .sha256 beside it before installing it. An APK built from a
checkout of the app's repository is installed by naming the file.

An app signed with a different key cannot be updated in place — adb refuses the
install — so --replace-signer uninstalls it first. That also clears the app's
saved proxies; --yes skips the prompt. It is what a phone moving from a locally
built APK to a signed release needs, once. For this app, the saved proxies are
exported to PHONE_PROXY_BACKUP first, imported back after the install, and the
proxy that was in use is started and verified on the port it had; if the
installed app cannot export, nothing is uninstalled. The backup holds every
password in clear text and is written mode 0600 beside the secrets.

Downloads are cached in $PHONE_APK_DIR, defaulting to
$XDG_CACHE_HOME/phone-link (or ~/.cache/phone-link), named
<pkg>-<version>-<code>.apk for F-Droid and after the release's asset otherwise.
"""

USAGE_ADB_WIFI = """usage: phone-adb-wifi [--legacy | --tls] [--check]

Enables adb over Wi-Fi: the legacy `adb tcpip 5555` listener and Android 11+
wireless debugging on its random TLS port, then connects to both. --legacy or
--tls picks one; --check only reports the current state.
"""


def _only_help(args: list[str], usage: str) -> None:
    for value in args:
        if value in ("-h", "--help"):
            print(usage, end="", file=sys.stderr)
            raise SystemExit(0)
        print(usage, end="", file=sys.stderr)
        die(f"unknown argument: {value}")


def _serial() -> str:
    serial = phone.phone_serial()
    if not serial:
        die("no phone attached (see adb devices)")
    return serial


def _shell(serial: str, *command: str) -> str:
    """One adb shell call, with CRs removed and the trailing newline trimmed."""
    return capture(["adb", "-s", serial, "shell", *command]).replace("\r", "")


def _first_line(text: str) -> str:
    lines = text.splitlines()
    return lines[0] if lines else ""


def _print_devices() -> None:
    devices = capture(["adb", "devices"])
    if devices:
        print(devices)


def phone_fix_mobile_data(args: list[str]) -> int:
    """Turn the phone's mobile data on when it has no default route."""
    _only_help([value for value in args if value != "--check"], USAGE_MOBILE_DATA)
    check_only = "--check" in args
    serial = _serial()

    def default_route() -> str:
        return _first_line(_shell(serial, "ip", "route", "show", "default"))

    route = default_route()
    if check_only:
        log(f"default route: {route or 'none'}")
        return 0 if route else 1
    if route:
        log(f"the phone already has a default route ({route})")
        return 0

    log("enabling mobile data")
    if status(["adb", "-s", serial, "shell", "svc", "data", "enable"]) != 0:
        die("svc data enable failed")

    for _ in range(10):
        time.sleep(1)
        route = default_route()
        if route:
            log(f"mobile data is up ({route})")
            return 0
    die("mobile data was enabled but no default route appeared")
    return 1


def phone_wifi_enable(args: list[str]) -> int:
    """Enable the phone's Wi-Fi radio, or report its state."""
    _only_help([value for value in args if value != "--check"], USAGE_WIFI_ENABLE)
    check_only = "--check" in args
    serial = _serial()

    def wifi_enabled() -> bool:
        lines = _shell(serial, "cmd", "wifi", "status").splitlines()
        return any(line.startswith("Wifi is enabled") for line in lines)

    if wifi_enabled():
        log("Wi-Fi is enabled")
        return 0
    if check_only:
        log("Wi-Fi is disabled")
        return 1

    status(["adb", "-s", serial, "shell", "cmd", "wifi", "set-wifi-enabled", "enabled"])
    for _ in range(settings.PHONE_WIFI_TRIES):
        time.sleep(settings.PHONE_WIFI_POLL)
        if wifi_enabled():
            log("Wi-Fi enabled")
            return 0
    die("Wi-Fi did not come up")
    return 1


def phone_wifi_forget(args: list[str]) -> int:
    """Forget a saved Wi-Fi network on the phone (default PhoneLink)."""
    ssid = settings.PHONE_AP_SSID
    check_only = False
    assume_yes = False
    for value in args:
        if value == "--check":
            check_only = True
        elif value == "--yes":
            assume_yes = True
        elif value in ("-h", "--help"):
            print(USAGE_WIFI_FORGET, end="", file=sys.stderr)
            return 0
        elif value.startswith("-"):
            print(USAGE_WIFI_FORGET, end="", file=sys.stderr)
            die(f"unknown argument: {value}")
        else:
            ssid = value

    serial = _serial()

    def network_id() -> str:
        # The list is "id   SSID   security"; the SSID may contain spaces, so
        # split on runs of two or more spaces.
        for line in _shell(serial, "cmd", "wifi", "list-networks").splitlines():
            parts = re.split(r"\s{2,}", line.strip())
            if len(parts) >= 3 and parts[1] == ssid:
                return parts[0]
        return ""

    network = network_id()
    if not network:
        log(f"{ssid} is not saved")
        return 0
    if check_only:
        log(f"{ssid} is saved (network id {network})")
        return 1

    if not assume_yes:
        sys.stderr.write(f"Forget {ssid} on the phone? [y/N] ")
        sys.stderr.flush()
        try:
            with open("/dev/tty", encoding="utf-8") as tty:
                answer = tty.readline().strip()
        except OSError:
            answer = ""
        if answer not in ("y", "Y", "yes", "YES"):
            die("aborted")

    log(f"forgetting {ssid} (network id {network})")
    status(["adb", "-s", serial, "shell", "cmd", "wifi", "forget-network", network])
    if network_id():
        die(f"{ssid} is still saved")
    log(f"{ssid} forgotten")
    return 0


def phone_usb_tether_default(args: list[str]) -> int:
    """Make USB tethering the default USB action while keeping adb."""
    _only_help([value for value in args if value != "--check"], USAGE_TETHER_DEFAULT)
    check_only = "--check" in args
    serial = _serial()

    def read_state() -> tuple[str, str]:
        config = _first_line(_shell(serial, "getprop", "sys.usb.config"))
        unlocked = ""
        for line in _shell(serial, "dumpsys", "usb").splitlines():
            match = re.search(r"screen_unlocked_functions=(.*)$", line)
            if match:
                unlocked = match.group(1)
                break
        return config, unlocked

    def is_rndis(value: str) -> bool:
        return "rndis" in value.lower()

    config, unlocked = read_state()
    current = is_rndis(config)
    default = is_rndis(unlocked)

    if check_only:
        log(f"current:  {config or 'unknown'} (USB tethering {'active' if current else 'no'})")
        log(f"default:  {unlocked or 'unknown'} (tether on unlock {'enabled' if default else 'no'})")
        if current and default:
            log("verdict:  USB tethering is the default USB action")
            return 0
        log("verdict:  USB tethering is not the default USB action")
        return 1

    if not current:
        log("setting current USB functions to rndis,adb")
        status(["adb", "-s", serial, "shell", "svc", "usb", "setFunctions", "rndis,adb"])
    if not default:
        log("setting screen-unlocked USB functions to rndis,adb")
        status(
            [
                "adb",
                "-s",
                serial,
                "shell",
                "svc",
                "usb",
                "setScreenUnlockedFunctions",
                "rndis,adb",
            ]
        )

    # Changing functions makes the adb client abort while the gadget
    # re-enumerates, so a setter can be lost. Re-read and re-issue only what is
    # still missing.
    tries = 0
    while True:
        config, unlocked = read_state()
        current = is_rndis(config)
        default = is_rndis(unlocked)
        if current and default:
            break
        if tries >= settings.PHONE_TETHER_TRIES:
            break
        if not current:
            status(
                ["adb", "-s", serial, "shell", "svc", "usb", "setFunctions", "rndis,adb"]
            )
        if not default:
            status(
                [
                    "adb",
                    "-s",
                    serial,
                    "shell",
                    "svc",
                    "usb",
                    "setScreenUnlockedFunctions",
                    "rndis,adb",
                ]
            )
        tries += 1
        time.sleep(1)

    if not is_rndis(config):
        die(f"USB tethering did not become current (sys.usb.config={config})")
    if not is_rndis(unlocked):
        die(
            "USB tethering did not become the default "
            f"(screen_unlocked_functions={unlocked})"
        )
    log(
        f"USB tethering is now the default USB action "
        f"(current {config}, on unlock {unlocked})"
    )
    return 0


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
                "adb", "-s", serial, "shell", "pm", "grant", package,
                f"android.permission.{permission}",
            ]
        )
    if not whitelisted():
        status(
            [
                "adb", "-s", serial, "shell", "cmd", "deviceidle", "whitelist",
                f"+{package}",
            ]
        )
    if auto_start() != "true":
        status(
            [
                "adb", "-s", serial, "shell", "am", "start-foreground-service",
                "-n", service, "-a", f"{package}.action.START",
                "--ez", "auto_start", "true",
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


def _confirm_stdin(prompt: str) -> bool:
    """Ask on stdin when it is a terminal; anything else refuses."""
    if not sys.stdin.isatty():
        return False
    sys.stderr.write(prompt)
    sys.stderr.flush()
    return sys.stdin.readline().strip() in ("y", "Y", "yes", "YES")


def phone_proxy_data_clear(args: list[str]) -> int:
    """Delete the proxy app's data (port, credentials, auto-start flag)."""
    assume_yes = False
    check_only = False
    for value in args:
        if value in ("-y", "--yes"):
            assume_yes = True
        elif value == "--check":
            check_only = True
        elif value in ("-h", "--help"):
            print(USAGE_DATA_CLEAR, end="", file=sys.stderr)
            return 0
        else:
            print(USAGE_DATA_CLEAR, end="", file=sys.stderr)
            die(f"unknown argument: {value}")

    serial = _serial()
    package = settings.PHONE_PROXY_PKG
    log(f"phone: {serial}")

    if not _shell(serial, "pm", "path", package):
        log(f"{package}: not installed, nothing to clear")
        log("data left behind by a --keep-data uninstall is only removed by a full")
        log("uninstall, or by reinstalling and running this script")
        return 0
    if check_only:
        log(f"would run: adb -s {serial} shell pm clear {package}")
        return 0

    if not assume_yes:
        prompt = (
            f"Delete all data of {package} on {serial} "
            "(port, credentials, auto-start)? [y/N] "
        )
        if not sys.stdin.isatty():
            die("refusing to clear data without --yes (not a terminal)")
        if not _confirm_stdin(prompt):
            log("aborted")
            return 1

    output = capture(["adb", "-s", serial, "shell", "pm", "clear", package]).replace(
        "\r", ""
    )
    if "Success" not in output:
        die(f"pm clear failed: {output or 'no output'}")

    # The app is force-stopped, so no LAN address should still accept
    # connections.
    left = False
    for _ in range(5):
        left = False
        for address in phone.phone_ips(serial):
            if phone.tcp_open(address, 1):
                left = True
        if not left:
            break
        time.sleep(1)

    log(
        f"cleared {package} data "
        "(port back to 1080, auth disabled, auto-start off)"
    )
    if left:
        log("warning: a LAN address still accepts connections; the app may have restarted")
    log("the proxy is gone: the tunnel stops within 5 s; run phone-proxy-setup to restore it")
    return 0


def phone_proxy_uninstall(args: list[str]) -> int:
    """Uninstall the phone's SOCKS proxy app."""
    assume_yes = False
    keep_data = False
    check_only = False
    for value in args:
        if value in ("-y", "--yes"):
            assume_yes = True
        elif value == "--keep-data":
            keep_data = True
        elif value == "--check":
            check_only = True
        elif value in ("-h", "--help"):
            print(USAGE_UNINSTALL, end="", file=sys.stderr)
            return 0
        else:
            print(USAGE_UNINSTALL, end="", file=sys.stderr)
            die(f"unknown argument: {value}")

    serial = _serial()
    package = settings.PHONE_PROXY_PKG
    log(f"phone: {serial}")

    paths = [
        line.removeprefix("package:")
        for line in _shell(serial, "pm", "path", package).splitlines()
        if line.startswith("package:")
    ]
    if not paths:
        log(f"{package}: not installed, nothing to do")
        return 0

    version = ""
    for line in _shell(serial, "dumpsys", "package", package).splitlines():
        match = re.match(r" *versionName=(.*)$", line)
        if match:
            version = match.group(1)
            break
    log(f"{package}: installed, version {version or 'unknown'}")
    for path in paths:
        log(f"  {path}")

    # `adb uninstall -k` is refused on Android 15 (it points at `cmd package`
    # instead), so keeping data goes through the package manager directly.
    command = (
        ["shell", "cmd", "package", "uninstall", "-k", package]
        if keep_data
        else ["uninstall", package]
    )

    if check_only:
        log(f"would run: adb -s {serial} {' '.join(command)}")
        return 0

    if not assume_yes:
        prompt = f"Uninstall {package} from {serial}? [y/N] "
        if not sys.stdin.isatty():
            die("refusing to uninstall without --yes (not a terminal)")
        if not _confirm_stdin(prompt):
            log("aborted")
            return 1

    if status(["adb", "-s", serial, *command]) != 0:
        die("adb uninstall failed")
    if _shell(serial, "pm", "path", package):
        die("still installed after uninstall")

    log(f"uninstalled {package}{' (data kept)' if keep_data else ''}")
    log("the proxy is gone: the tunnel stops within 5 s; run phone-net-status")
    return 0


def phone_proxy_install(args: list[str]) -> int:
    """Install, update, pull or report the phone's SOCKS proxy app."""
    mode = "install"
    use_fdroid = False
    use_release = False
    replace_signer = False
    assume_yes = False
    extra: list[str] = []
    index = 0
    while index < len(args):
        value = args[index]
        if value == "--pull":
            mode = "pull"
        elif value == "--status":
            mode = "status"
        elif value == "--check":
            mode = "check"
        elif value == "--install":
            mode = "install"
        elif value == "--fdroid":
            use_fdroid = True
        elif value == "--release":
            use_release = True
        elif value == "--build":
            # The app has its own repository and its own build now, so this
            # checkout cannot produce the APK. Say where it comes from instead
            # of failing as if the option were never ours.
            print(USAGE_INSTALL, end="", file=sys.stderr)
            die(
                "the app is built in its own repository "
                f"({settings.PHONE_PROXY_REPO}): install a release with "
                "--release, or name an APK you built there"
            )
        elif value == "--replace-signer":
            replace_signer = True
        elif value in ("-y", "--yes"):
            assume_yes = True
        elif value in ("-h", "--help"):
            print(USAGE_INSTALL, end="", file=sys.stderr)
            return 0
        elif value == "--":
            extra.extend(args[index + 1 :])
            break
        elif value.startswith("-"):
            print(USAGE_INSTALL, end="", file=sys.stderr)
            die(f"unknown option: {value}")
        else:
            extra.append(value)
        index += 1

    if mode == "status" and use_fdroid:
        die("--status does not download; drop --fdroid")
    if mode == "pull" and use_fdroid:
        die("--pull reads the phone, not F-Droid; drop --fdroid")
    if use_fdroid and extra:
        die("--fdroid fetches the APK itself; drop the path argument")
    if use_fdroid and use_release:
        die("--fdroid and --release both fetch an APK; pick one")
    if use_release and mode in ("status", "pull"):
        die(f"--{mode} does not download; drop --release")
    if use_release and len(extra) > 1:
        die("--release takes one tag at most")
    if replace_signer and mode == "check":
        die("--check installs nothing; drop --replace-signer")

    serial = _serial()
    package = settings.PHONE_PROXY_PKG
    log(f"phone: {serial}")

    # The saved proxies live in the app, so replacing a differently signed app
    # has to get them out first. Imported here, not at module load, because the
    # proxy commands import this module.
    from . import proxy as proxy_commands

    def remote_paths() -> list[str]:
        return [
            line.removeprefix("package:")
            for line in _shell(serial, "pm", "path", package).splitlines()
            if line.startswith("package:")
        ]

    def installed_version() -> str:
        for line in _shell(serial, "dumpsys", "package", package).splitlines():
            match = re.match(r" *versionName=(.*)$", line)
            if match:
                return match.group(1)
        return ""

    def show_status() -> int:
        paths = remote_paths()
        if not paths:
            log(f"{package}: not installed")
            return 1
        log(f"{package}: installed, version {installed_version() or 'unknown'}")
        for path in paths:
            log(f"  {path}")
        return 0

    def cache_dir() -> str:
        return os.environ.get("PHONE_APK_DIR") or (
            os.path.join(
                os.environ.get("XDG_CACHE_HOME") or os.path.join(
                    os.environ.get("HOME", ""), ".cache"
                ),
                "phone-link",
            )
        )

    def download(url: str, destination: str, *, timeout: float = 330) -> bool:
        """Fetch url to destination, writing nothing when it fails."""
        code, _ = run_text(
            ["curl", "-fsSL", "--max-time", "300", "-o", f"{destination}.part", url],
            timeout=timeout,
        )
        if code != 0:
            try:
                os.unlink(f"{destination}.part")
            except OSError:
                pass
            return False
        return True

    def release_apk() -> str:
        """The APK attached to a release of the app's repository, checked."""
        repo = settings.PHONE_PROXY_REPO
        tag = extra[0] if extra else ""
        wanted = tag or "latest"
        api = (
            f"https://api.github.com/repos/{repo}/releases/tags/{tag}"
            if tag
            else f"https://api.github.com/repos/{repo}/releases/latest"
        )
        code, body = run_text(["curl", "-fsSL", "--max-time", "30", api], timeout=40)
        if code != 0:
            die(f"cannot read the {wanted} release of {repo}")
        # The release's assets are the only thing needed from the document, and
        # the APK is the one asset without a suffix.
        urls = re.findall(r'"browser_download_url":\s*"([^"]+)"', body)
        apk_url = next((url for url in urls if url.endswith(".apk")), "")
        if not apk_url:
            die(f"the {wanted} release of {repo} has no APK attached")
        name = apk_url.rsplit("/", 1)[-1]
        log(f"release: {wanted} ({name})")

        cache = cache_dir()
        file = os.path.join(cache, name)
        if os.path.isfile(file) and os.path.getsize(file) > 0:
            log(f"cached: {file}")
            return file
        os.makedirs(cache, exist_ok=True)
        if not download(apk_url, file):
            die(f"download failed: {apk_url}")

        # A release carries the checksum beside the APK; without one there is
        # nothing to compare, which is said rather than passed over.
        expected = ""
        code, sums = run_text(["curl", "-fsSL", "--max-time", "30", apk_url + ".sha256"], timeout=40)
        if code == 0 and sums.strip():
            expected = sums.split()[0]
        with open(f"{file}.part", "rb") as handle:
            digest = hashlib.sha256(handle.read()).hexdigest()
        if expected:
            if digest != expected:
                os.unlink(f"{file}.part")
                die(f"checksum mismatch for {name}: downloaded {digest}, release says {expected}")
            log(f"checksum: {digest} matches the release")
        else:
            log("warning: the release carries no .sha256; the download is unchecked")
        os.replace(f"{file}.part", file)
        log(f"downloaded: {file} ({os.path.getsize(file)} bytes)")
        return file

    def fdroid_latest() -> str:
        api = f"https://f-droid.org/api/v1/packages/{package}"
        code, body = run_text(["curl", "-fsSL", "--max-time", "30", api], timeout=40)
        if code != 0:
            die(f"{package} is not on F-Droid (or the API is unreachable)")
        match = re.search(r'"suggestedVersionCode":([0-9]+)', body)
        if not match:
            die(f"F-Droid lists no suggested version for {package}")
        version_code = match.group(1)
        name_match = re.search(
            rf'"versionName":"([^"]*)","versionCode":{version_code}', body
        )
        name = name_match.group(1) if name_match else ""
        log(f"F-Droid: {name or 'versionCode ' + version_code} (versionCode {version_code})")

        cache = cache_dir()
        # Keyed by versionCode too: a rebuild can keep versionName and still
        # be new.
        file = os.path.join(
            cache, f"{package}-{name or 'unknown'}-{version_code}.apk"
        )
        if os.path.isfile(file) and os.path.getsize(file) > 0:
            log(f"cached: {file}")
        else:
            os.makedirs(cache, exist_ok=True)
            url = f"https://f-droid.org/repo/{package}_{version_code}.apk"
            code, _ = run_text(
                ["curl", "-fsSL", "--max-time", "300", "-o", f"{file}.part", url],
                timeout=330,
            )
            if code != 0:
                try:
                    os.unlink(f"{file}.part")
                except OSError:
                    pass
                die(f"download failed: {package} versionCode {version_code}")
            os.replace(f"{file}.part", file)
            log(f"downloaded: {file} ({os.path.getsize(file)} bytes)")
        return file

    def pull_apks(destination: str) -> int:
        paths = remote_paths()
        if not paths:
            die(f"{package} is not installed on {serial}")
        os.makedirs(destination, exist_ok=True)
        for path in paths:
            log(f"pull {path}")
            if status(["adb", "-s", serial, "pull", path, f"{destination}/"]) != 0:
                die(f"pull failed: {path}")

        # A single base.apk gets a self-describing name so reinstalls need no
        # guess.
        if len(paths) == 1:
            source = os.path.join(destination, os.path.basename(paths[0]))
            target = os.path.join(
                destination,
                f"{package}-{installed_version() or 'unknown'}.apk",
            )
            os.replace(source, target)

        listing = capture(["ls", "-l", destination])
        if listing:
            log(listing)
        log(f"install later with: phone-proxy-install {destination}/*.apk")
        return 0

    def install_apks(apks: list[str]) -> None:
        one = len(apks) == 1
        argv = (
            ["adb", "-s", serial, "install", "-r", "-g", apks[0]]
            if one
            else ["adb", "-s", serial, "install-multiple", "-r", "-g", *apks]
        )
        # adb says why it refused; the reason decides what to say next, so the
        # output is kept and printed rather than dropped.
        code, output = run_both(argv, timeout=300)
        if output.strip():
            log(output.strip())
        if code != 0:
            if "INSTALL_FAILED_UPDATE_INCOMPATIBLE" in output or "ignature" in output:
                die(
                    "the installed app is signed with a different key, so adb "
                    "cannot update it in place: --replace-signer uninstalls it "
                    "first (which clears the app's saved proxies)"
                )
            die("adb install failed" if one else "adb install-multiple failed")
        grant_settings()

    def grant_settings() -> None:
        """Let our own app switch wireless debugging back on.

        WRITE_SECURE_SETTINGS is a development permission: adb can hand it out
        and nothing on the phone can, so it belongs to the install rather than
        to a step somebody has to remember. Only for the APK this repository
        builds — a third-party proxy has no business holding it, and the grant
        fails harmlessly for one that does not declare it.
        """
        if not package.startswith(settings.PHONE_APP_NAMESPACE):
            return
        argv = [
            "adb",
            "-s",
            serial,
            "shell",
            "pm",
            "grant",
            package,
            "android.permission.WRITE_SECURE_SETTINGS",
        ]
        if status(argv) != 0:
            log(
                "warning: cannot grant WRITE_SECURE_SETTINGS; the panel's "
                "wireless-debugging switch will not work"
            )
            return
        log("granted WRITE_SECURE_SETTINGS: the app can turn wireless debugging back on")
        # The device-idle allowlist is kept by package and goes away with the
        # uninstall, so an app put back is not yet the app that came back after
        # a reboot. Put the entry back with the install rather than leaving it
        # to a step somebody has to remember.
        argv = [
            "adb",
            "-s",
            serial,
            "shell",
            "cmd",
            "deviceidle",
            "whitelist",
            f"+{package}",
        ]
        if status(argv) == 0:
            log("on the battery allowlist: the app can come back after a reboot")
        else:
            log("warning: cannot add the app to the battery allowlist (run phone-proxy-boot)")

    if mode == "status":
        return show_status()
    if mode == "pull":
        return pull_apks(extra[0] if extra else os.path.join(os.getcwd(), "apk"))

    # A bare install is the newest release of the app's own repository: this
    # checkout used to build it, and no longer does.
    local_apks: list[str] = []
    if use_release:
        # extra[0], when there is one, is the tag to take.
        local_apks = [release_apk()]
    elif use_fdroid:
        local_apks = [fdroid_latest()]
    elif extra:
        local_apks = list(extra)
    else:
        local_apks = [release_apk()]

    for apk in local_apks:
        if not os.path.isfile(apk):
            die(f"not a file: {apk}")
        log(f"APK: {apk} ({os.path.getsize(apk)} bytes)")

    if mode == "check":
        log("check only; nothing installed")
        return 0

    # An app signed with another key cannot be updated in place; the only way
    # onto a differently signed build is to remove the old one, and the app's
    # data goes with it. Said before it happens, and asked about unless --yes.
    # Our own app is asked for its saved proxies first, so the uninstall does
    # not cost them; the backup is written root-only beside the secrets.
    restore_document: dict | None = None
    installed = remote_paths()
    if replace_signer and installed:
        log(
            f"{package} is installed: replacing it with a differently signed "
            "build uninstalls it first, which clears the app's saved proxies"
        )
        if not assume_yes:
            if not sys.stdin.isatty():
                die("refusing to replace the app without --yes (not a terminal)")
            if not _confirm_stdin(f"Uninstall {package} and install over it? [y/N] "):
                log("aborted")
                return 1
        if package.startswith(settings.PHONE_APP_NAMESPACE):
            if not proxy_commands.backup_writable():
                # The backup belongs beside the root-only secrets; the export
                # writes it there, so run the whole replacement as root.
                phone.as_root("phone-proxy-install", args)
            log("exporting the saved proxies before the uninstall")
            restore_document = proxy_commands.export_to(
                serial, settings.PHONE_PROXY_BACKUP
            )
        else:
            log(
                "the vendored proxy has no export action; its saved proxies "
                "will be lost with the uninstall"
            )
        if status(["adb", "-s", serial, "uninstall", package]) != 0:
            die("adb uninstall failed")
        log(f"uninstalled {package}")

    install_apks(local_apks)
    if restore_document is not None:
        # The app is back and empty; put its saved proxies back and prove the
        # proxy that was in use answers on the port it had before.
        log("importing the saved proxies after the install")
        proxy_commands.restore(
            serial, restore_document, settings.PHONE_PROXY_BACKUP
        )
    show_status()
    if restore_document is not None:
        log("the app's saved proxies are back; phone-proxy-check reports the link")
    else:
        log("open the app once and start the proxy, then run phone-proxy-check")
    return 0


def phone_adb_wifi(args: list[str]) -> int:
    """Enable adb over Wi-Fi: the legacy TCP port and wireless debugging."""
    legacy = tls = False
    mode_given = False
    check_only = False
    for value in args:
        if value == "--legacy":
            if not mode_given:
                legacy = tls = False
                mode_given = True
            legacy = True
        elif value == "--tls":
            if not mode_given:
                legacy = tls = False
                mode_given = True
            tls = True
        elif value == "--check":
            check_only = True
        elif value in ("-h", "--help"):
            print(USAGE_ADB_WIFI, end="", file=sys.stderr)
            return 0
        else:
            print(USAGE_ADB_WIFI, end="", file=sys.stderr)
            die(f"unknown argument: {value}")
    if not mode_given:
        legacy = tls = True

    serial = _serial()
    if not have("avahi-browse"):
        log("warning: avahi-browse is missing, cannot read the wireless debugging port")

    def wifi_debugging() -> str:
        return _first_line(_shell(serial, "settings", "get", "global", "adb_wifi_enabled"))

    def legacy_port() -> str:
        return _first_line(_shell(serial, "getprop", "service.adb.tcp.port"))

    def tls_endpoint() -> str | None:
        # The TLS port is random and not exported as a property; adbd
        # advertises it over mDNS as adb-<serial>-<random>.
        if not have("avahi-browse"):
            return None
        output = capture(["avahi-browse", "-rt", "_adb-tls-connect._tcp"], timeout=15)
        seen = False
        address = ""
        port = ""
        for line in output.splitlines():
            if (
                line.startswith("=")
                and "IPv4" in line
                and f"adb-{serial}" in line
            ):
                seen = True
                continue
            if not seen:
                continue
            match = re.search(r"address = \[([^\]]*)\]", line)
            if match:
                address = match.group(1)
            match = re.search(r"port = \[([^\]]*)\]", line)
            if match:
                port = match.group(1)
            if address and port:
                return f"{address}:{port}"
        return None

    if check_only:
        log(f"wireless debugging: {wifi_debugging() or 'unknown'}")
        log(f"legacy tcp port:  {legacy_port() or 'not set'}")
        endpoint = tls_endpoint()
        log(f"tls endpoint:     {endpoint or 'not advertised'}")
        _print_devices()
        return 0

    addresses = phone.phone_ips(serial)

    if tls:
        if wifi_debugging() == "1":
            log("wireless debugging already enabled")
        else:
            status(
                ["adb", "-s", serial, "shell", "settings", "put", "global",
                 "adb_wifi_enabled", "1"]
            )
            log("enabled wireless debugging (random TLS port)")

    if legacy:
        if legacy_port() == settings.PHONE_ADB_PORT:
            log(f"legacy adbd already on {settings.PHONE_ADB_PORT}")
        else:
            log(
                f"warning: adb tcpip {settings.PHONE_ADB_PORT} restarts adbd "
                "(USB adb and the tether blip)"
            )
            if status(
                ["adb", "-s", serial, "tcpip", settings.PHONE_ADB_PORT]
            ) != 0:
                die("adb tcpip failed")
            time.sleep(settings.PHONE_ADB_POLL)

        connected = False
        candidates = list(
            dict.fromkeys(
                [
                    address
                    for address in [
                        *addresses,
                        settings.PHONE_HOTSPOT_IP,
                        settings.PHONE_AP_IP,
                    ]
                    if address
                ]
            )
        )
        for address in candidates:
            target = f"{address}:{settings.PHONE_ADB_PORT}"
            if status(["adb", "connect", target], timeout=20) != 0:
                continue
            if capture(["adb", "-s", target, "get-state"]) == "device":
                log(f"legacy adb on {target}")
                connected = True
                break
        if not connected:
            die(f"no phone address answered on {settings.PHONE_ADB_PORT}")

    if tls:
        # adbd may still advertise the old port for a moment after a restart,
        # so reconnect until one of the advertised endpoints really accepts
        # adb.
        reachable = False
        for _ in range(8):
            endpoint = tls_endpoint()
            if endpoint:
                status(["adb", "connect", endpoint], timeout=20)
                if capture(["adb", "-s", endpoint, "get-state"]) == "device":
                    log(f"wireless debugging on {endpoint}")
                    reachable = True
                    break
            time.sleep(settings.PHONE_ADB_POLL)
        if not reachable:
            if not legacy:
                die("wireless debugging did not become reachable")
            log("warning: wireless debugging is on but no TLS port accepted adb")

    _print_devices()
    return 0


def adb_wifi_connect(args: list[str]) -> int:
    """Connect adb to the phone over TCP."""
    if args and args[0] == "--prepare":
        log("warning: adb tcpip resets the USB gadget (the tether will blip)")
        serial = _serial()
        if status(["adb", "-s", serial, "tcpip", settings.PHONE_ADB_PORT]) != 0:
            die("adb tcpip failed (cable attached?)")
        time.sleep(settings.PHONE_ADB_POLL)

    target = ""
    for address in [*phone.phone_ips(), settings.PHONE_HOTSPOT_IP, settings.PHONE_AP_IP]:
        if phone.tcp_open(address, 2, int(settings.PHONE_ADB_PORT)):
            target = address
            break
    if not target:
        die("no adb TCP listener reachable on the phone")

    if status(["adb", "connect", f"{target}:{settings.PHONE_ADB_PORT}"]) != 0:
        die("adb connect failed")
    _print_devices()
    transport = phone.adb_transport()
    if transport:
        log(f"adb over Wi-Fi: {transport}")
    return 0
