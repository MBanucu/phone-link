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
PHONE_PROXY_PKG = _env("PHONE_PROXY_PKG", "com.tokyoxpa3.androidproxy")
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
