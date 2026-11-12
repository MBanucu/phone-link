"""The adb-only commands: phone settings, proxy app and adb over Wi-Fi.

These actions change only the phone and need no root. Every adb call is pinned
to one serial, because two transports (USB and Wi-Fi) are normal here and a
bare `adb` refuses to choose between them.
"""

from __future__ import annotations

import os
import re
import sys
import time
from pathlib import Path

from .. import phone, settings
from ..shell import capture, die, have, log, run_text, status

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
       phone-proxy-install --pull [DIR]
       phone-proxy-install --status
       phone-proxy-install --check APK

Installs or updates the phone's SOCKS proxy app over adb (-r -g), optionally
fetching F-Droid's suggested version first, pulls the installed APK off the
phone for later reinstalls, or reports what is installed.

--fdroid caches downloads in $PHONE_APK_DIR, defaulting to
$XDG_CACHE_HOME/phone-link (or ~/.cache/phone-link), named
<pkg>-<version>-<code>.apk.
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

    serial = _serial()
    package = settings.PHONE_PROXY_PKG
    log(f"phone: {serial}")

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

    def find_apk() -> str | None:
        # The current directory, the usual download spots, then the
        # repository's apk/ folder; prefer a file whose name says "proxy".
        script_dir = Path(__file__).resolve().parents[3] / "bin"
        candidates = [
            os.getcwd(),
            os.environ.get("PHONE_APK_DIR", ""),
            str(Path.home() / "Downloads") if os.environ.get("HOME") else "",
            str(Path.home() / "Desktop") if os.environ.get("HOME") else "",
            str(script_dir.parent / "apk"),
        ]
        for directory in candidates:
            if not directory or not os.path.isdir(directory):
                continue
            files = sorted(Path(directory).glob("*.apk"))
            if not files:
                continue
            for file in files:
                if "proxy" in file.name:
                    return str(file)
            return str(files[0])
        return None

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

        cache = os.environ.get("PHONE_APK_DIR") or (
            os.path.join(
                os.environ.get("XDG_CACHE_HOME") or os.path.join(
                    os.environ.get("HOME", ""), ".cache"
                ),
                "phone-link",
            )
        )
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
        if len(apks) == 1:
            if status(["adb", "-s", serial, "install", "-r", "-g", apks[0]]) != 0:
                die("adb install failed")
        elif (
            status(["adb", "-s", serial, "install-multiple", "-r", "-g", *apks]) != 0
        ):
            die("adb install-multiple failed")

    if mode == "status":
        return show_status()
    if mode == "pull":
        return pull_apks(extra[0] if extra else os.path.join(os.getcwd(), "apk"))

    local_apks: list[str] = []
    if use_fdroid:
        local_apks = [fdroid_latest()]
    elif extra:
        local_apks = list(extra)
    else:
        found = find_apk()
        if not found:
            die("no APK found; pass one, or fetch it with --fdroid")
        local_apks = [found]

    for apk in local_apks:
        if not os.path.isfile(apk):
            die(f"not a file: {apk}")
        log(f"APK: {apk} ({os.path.getsize(apk)} bytes)")

    if mode == "check":
        log("check only; nothing installed")
        return 0

    install_apks(local_apks)
    show_status()
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
            time.sleep(2)

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
            time.sleep(2)
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
        if status(["adb", "tcpip", settings.PHONE_ADB_PORT]) != 0:
            die("adb tcpip failed (cable attached?)")
        time.sleep(2)

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
