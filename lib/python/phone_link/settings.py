"""Environment-backed settings shared by the commands.

Mirrors lib/phone-net.sh: every value comes from the environment when set and
falls back to the same default, so a command behaves identically whether it is
started from a shell, the GUI or a Nix store wrapper.
"""

from __future__ import annotations

import os


def _env(name: str, default: str) -> str:
    # Bash uses ${NAME:-default}: an empty value means "unset", not "".
    return os.environ.get(name) or default


PHONE_SERIAL = _env("PHONE_SERIAL", "XPLO2EEA0001541")
PHONE_HOTSPOT_IP = _env("PHONE_HOTSPOT_IP", "10.244.108.165")
PHONE_AP_IP = _env("PHONE_AP_IP", "192.168.77.232")
PHONE_AP_CON = _env("PHONE_AP_CON", "phonelink")
PHONE_AP_SSID = _env("PHONE_AP_SSID", "PhoneLink")
PHONE_AP_IF = _env("PHONE_AP_IF", "wlp110s0")
PHONE_AP_ADDRESS = _env("PHONE_AP_ADDRESS", "192.168.77.1/24")
PHONE_AP_DECLARATIVE = _env("PHONE_AP_DECLARATIVE", "/etc/phone-link/ap-profile")
PHONE_AP_ENSURE_UNIT = _env(
    "PHONE_AP_ENSURE_UNIT", "NetworkManager-ensure-profiles.service"
)
PHONE_HOTSPOT_CON = _env("PHONE_HOTSPOT_CON", "XPLORE 2")
PHONE_HOTSPOT_SSID = _env("PHONE_HOTSPOT_SSID", PHONE_HOTSPOT_CON)
PHONE_PROXY_PORT = int(_env("PHONE_PROXY_PORT", "1080"))
PHONE_PROXY_USER = _env("PHONE_PROXY_USER", "proxy")
# The app in `android/`: it is the phone's proxy, and PHONE_PROXY_PKG is what a
# command means by "the proxy app". The vendored `com.tokyoxpa3.androidproxy`
# still works by overriding it, which is what the uninstall and data-clear
# commands are for.
PHONE_PROXY_PKG = _env("PHONE_PROXY_PKG", "org.phonelink.proxy")
PHONE_APP_PKG = _env("PHONE_APP_PKG", PHONE_PROXY_PKG)
# Whatever id it is installed under (the `.test` build included), our app is the
# one whose namespace this is: the vendored proxy is not, and must not be handed
# a development permission it has no use for.
PHONE_APP_NAMESPACE = "org.phonelink.proxy"
PHONE_ADB_PORT = _env("PHONE_ADB_PORT", "5555")
PHONE_SECRETS = _env("PHONE_SECRETS", "/etc/nixos/phone-socks-secrets")
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
