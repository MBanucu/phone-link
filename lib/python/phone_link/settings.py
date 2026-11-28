"""Environment-backed settings shared by the commands.

Mirrors lib/phone-net.sh: every value comes from the environment when set, then
from the non-secret file the NixOS module writes (``/etc/phone-link/env``), and
falls back to the same built-in default.  A command therefore behaves the same
whether it is started from a shell, the GUI or a Nix store wrapper, and a
deployment that sets a non-default ``phoneLink`` option no longer needs to
repeat it in the environment.
"""

from __future__ import annotations

import os

from .config import values as _config_values

_CONFIG = _config_values()


def _env(name: str, default: str) -> str:
    # Bash uses ${NAME:-default}: an empty value means "unset", not "".
    return os.environ.get(name) or _CONFIG.get(name) or default


# ADB's target serial is resolved at run time by phone_link.adb: PHONE_SERIAL
# first, then the only attached phone (transports grouped by hardware
# identity), else an error that lists the devices.
# There is deliberately no built-in serial here: a USB serial belongs to one
# phone and silently targeting it is how a destructive command hit the wrong
# device.
PHONE_HOTSPOT_IP = _env("PHONE_HOTSPOT_IP", "10.244.108.165")
# The primary proxy address. `phoneLink.proxyHost` is written here by the
# module; the old PHONE_AP_IP name is kept as the fallback because the AP
# address is what it meant.
PHONE_AP_IP = _env("PHONE_AP_IP", "192.168.77.232")
PHONE_PROXY_HOST = _env("PHONE_PROXY_HOST", PHONE_AP_IP)
PHONE_PROXY_HOSTS = tuple(
    host for host in _env("PHONE_PROXY_HOSTS", "").split() if host
)
PHONE_AP_CON = _env("PHONE_AP_CON", "phonelink")
# Who owns the AP: "local" is the profile this host declares; "external" is an
# always-on AP elsewhere, where the laptop is only a client. The module writes
# the value, so the commands and the doctor agree without another marker file.
PHONE_AP_ROLE = _env("PHONE_AP_ROLE", "local")
PHONE_AP_SSID = _env("PHONE_AP_SSID", "PhoneLink")
PHONE_AP_IF = _env("PHONE_AP_IF", "wlp110s0")
PHONE_AP_ADDRESS = _env("PHONE_AP_ADDRESS", "192.168.77.1/24")
PHONE_AP_BAND = _env("PHONE_AP_BAND", "a")
PHONE_AP_CHANNEL = _env("PHONE_AP_CHANNEL", "149")
PHONE_AP_CHANNEL_WIDTH = _env("PHONE_AP_CHANNEL_WIDTH", "80")
PHONE_AP_DECLARATIVE = _env("PHONE_AP_DECLARATIVE", "/etc/phone-link/ap-profile")
# The optional one-shot 2.4 GHz fallback: the script, the profile's fallback
# channel/width/delay, and the per-boot state file both the command and the
# boot unit share.  `PHONE_AP_FALLBACK` is "1" only when the module enabled it.
PHONE_AP_FALLBACK = _env("PHONE_AP_FALLBACK", "0")
PHONE_AP_FALLBACK_TOOL = _env(
    "PHONE_AP_FALLBACK_TOOL", "/etc/phone-link/ap-fallback.sh"
)
PHONE_AP_FALLBACK_STATE = _env("PHONE_AP_FALLBACK_STATE", "/run/phone-link/ap-fallback")
PHONE_AP_FALLBACK_CHANNEL = _env("PHONE_AP_FALLBACK_CHANNEL", "1")
PHONE_AP_FALLBACK_WIDTH = _env("PHONE_AP_FALLBACK_WIDTH", "20")
PHONE_AP_FALLBACK_DELAY = _env("PHONE_AP_FALLBACK_DELAY", "30")
PHONE_AP_ENSURE_UNIT = _env(
    "PHONE_AP_ENSURE_UNIT", "NetworkManager-ensure-profiles.service"
)
# The rejoin watchdog's throttle file and unit: phone-ap-up clears the file and
# starts the unit so a deliberate switch-on asks for the association at once
# instead of waiting out the five-minute window.
PHONE_AP_REJOIN_STATE = _env("PHONE_AP_REJOIN_STATE", "/run/phone-link/ap-rejoin.last")
PHONE_AP_REJOIN_UNIT = "phone-link-ap-rejoin.service"
PHONE_HOTSPOT_CON = _env("PHONE_HOTSPOT_CON", "XPLORE 2")
PHONE_HOTSPOT_SSID = _env("PHONE_HOTSPOT_SSID", PHONE_HOTSPOT_CON)
PHONE_PROXY_PORT = int(_env("PHONE_PROXY_PORT", "1080"))
# The port the laptop is actually using. `phoneLink.proxyPort` is only the
# default: `phone-proxy-switch` writes the chosen one here, and the units and
# the commands read it so a switch needs no rebuild. It lives in /run, so a
# reboot goes back to the module's value — which is the only one NixOS knows
# about without asking the phone.
PHONE_RUNTIME_DIR = _env("PHONE_RUNTIME_DIR", "/run/phone-link")
PHONE_RUNTIME_PORT_FILE = _env(
    "PHONE_RUNTIME_PORT_FILE", os.path.join(PHONE_RUNTIME_DIR, "proxy-port")
)
PHONE_PROXY_USER = _env("PHONE_PROXY_USER", "proxy")
# The app (`github:MBanucu/phone-link-proxy`): it is the phone's proxy, and
# PHONE_PROXY_PKG is what a command means by "the proxy app". The vendored
# `com.tokyoxpa3.androidproxy` still works by overriding it, which is what the
# uninstall and data-clear commands are for.
PHONE_PROXY_PKG = _env("PHONE_PROXY_PKG", "org.phonelink.proxy")
PHONE_APP_PKG = _env("PHONE_APP_PKG", PHONE_PROXY_PKG)
# Whatever id it is installed under (the `.test` build included), our app is the
# one whose namespace this is: the vendored proxy is not, and must not be handed
# a development permission it has no use for.
PHONE_APP_NAMESPACE = "org.phonelink.proxy"
# Where the app's release APKs come from: `phone-proxy-install`, `--release`
# and the ambulance box's repair kit all read this repository's releases. The
# app is a project of its own, so this is not the repository this checkout is
# in: nothing here builds the APK any more.
PHONE_PROXY_REPO = _env("PHONE_PROXY_REPO", "MBanucu/phone-link-proxy")
PHONE_ADB_PORT = _env("PHONE_ADB_PORT", "5555")
PHONE_SECRETS = _env("PHONE_SECRETS", "/etc/nixos/phone-socks-secrets")
# The saved proxies pulled off the phone live beside the secrets, root-only:
# the document holds every proxy's password in clear text. `phone-proxy-export`
# writes it 0600 and `phone-proxy-import` reads it back; `phone-proxy-install
# --replace-signer` uses the same file so an uninstall does not lose them.
PHONE_PROXY_BACKUP = _env(
    "PHONE_PROXY_BACKUP",
    os.path.join(os.path.dirname(PHONE_SECRETS), "phone-link-proxies.json"),
)
# How long to wait for the app's one-shot transfer socket after adb forward:
# the service binds on a background thread, so a refused connect for a moment
# is normal. A test with a stub adb sets it to 0.
PHONE_PROXY_TRANSFER_WAIT = float(_env("PHONE_PROXY_TRANSFER_WAIT", "8"))
PHONE_NM_SYSTEM_CONNECTIONS = _env(
    "PHONE_NM_SYSTEM_CONNECTIONS", "/etc/NetworkManager/system-connections"
)
PHONE_NM_RUN_CONNECTIONS = _env(
    "PHONE_NM_RUN_CONNECTIONS", "/run/NetworkManager/system-connections"
)
PHONE_APK_CACHE = _env("PHONE_APK_CACHE", "/var/cache/phone-link")
PHONE_WIFI_TRIES = int(_env("PHONE_WIFI_TRIES", "10"))
PHONE_WIFI_POLL = float(_env("PHONE_WIFI_POLL", "1"))
PHONE_TETHER_TRIES = int(_env("PHONE_TETHER_TRIES", "5"))
# How long to give the keyguard between attempts, and the screen between the
# uplink attempts phone-fix-internet makes. Both are real waits for a real
# phone — a lock screen animating, a network coming up — so they are seconds
# here and something like 0 in a test that has a stub for a phone: the tests of
# both commands used to spend most of their time asleep (45.8 s and 48.6 s),
# which is what makes a suite nobody dares to run.
PHONE_UNLOCK_POLL = float(_env("PHONE_UNLOCK_POLL", "1"))
PHONE_FIX_SETTLE = float(_env("PHONE_FIX_SETTLE", "1"))
# How long to give adbd after a restart before asking again: the wireless
# debugging endpoint advertises an old port for a moment, so phone-adb-wifi
# retries. Two seconds each here; a test with a stub adb sets it to 0.
PHONE_ADB_POLL = float(_env("PHONE_ADB_POLL", "2"))
# How long to give the app to put a listener on a port, and an old one to go
# away, before a switch gives up and says so. A test with a stub adb sets it
# to 0: the answer is already in the dump it just wrote.
PHONE_PROXY_WAIT = float(_env("PHONE_PROXY_WAIT", "15"))
PHONE_PROXY_SETTLE = float(_env("PHONE_PROXY_SETTLE", "5"))


def proxy_addresses() -> list[str]:
    """Every address worth probing, primary first, without duplicates."""
    addresses: list[str] = []
    for address in (PHONE_PROXY_HOST, *PHONE_PROXY_HOSTS, PHONE_HOTSPOT_IP):
        if address and address not in addresses:
            addresses.append(address)
    return addresses


def active_port() -> int:
    """The SOCKS port the laptop uses.

    PHONE_PROXY_PORT wins when it is set (a test, a one-off run), then the port
    `phone-proxy-switch` put under /run, then the module's default. A file that
    cannot be read or parsed is state, not a setting: it means nothing has
    switched yet, so the default is the answer.
    """
    if os.environ.get("PHONE_PROXY_PORT"):
        return PHONE_PROXY_PORT
    try:
        with open(PHONE_RUNTIME_PORT_FILE, encoding="utf-8") as handle:
            value = handle.read().strip()
    except OSError:
        return PHONE_PROXY_PORT
    if value.isdigit() and 1 <= int(value) <= 65535:
        return int(value)
    return PHONE_PROXY_PORT
