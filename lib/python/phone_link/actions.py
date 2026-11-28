"""The command registry: one entry per script in ../bin.

This table is the single source for the command surface. The flake's
`registry` check runs `phone_link.registry_gen --check`, which generates the
`bin/` shims, `commands/__init__.py` and the table in `docs/scripts.md` from
the entries below and fails when any of them disagrees. Adding a command is
therefore: its body, its entry here, and its test -- never a hand-edited shim
or docs row.

`kind` says where the body lives and how `registry_gen` builds the shim:

- ``action``  -- a function in `phone_link.commands.<area>`;
- ``doctor``  -- the `phone_doctor` package (an action, but not a commands
  function);
- ``cli``     -- the shared `phone-link` CLI;
- ``gui``     -- the GTK4 panel;
- ``tool``    -- a hand-written shell tool, listed here but not generated.

Flags are declared, not guessed: `supports_check` drives the "Check only"
entry, `supports_yes` decides whether a confirmed GUI run adds `--yes`, and
`root` decides whether the run escalates: through sudo when it can (one
password covers the following runs) and through pkexec otherwise.
"""

from __future__ import annotations

import importlib
import importlib.util
import os
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path

GROUPS: tuple[tuple[str, str], ...] = (
    ("status", "Status"),
    ("tunnel", "Tunnel"),
    ("ap", "Access point"),
    ("phone", "Phone and adb"),
    ("proxy", "Proxy app"),
    ("maintenance", "Maintenance"),
)

GROUP_ICONS = {
    "status": "utilities-system-monitor-symbolic",
    "tunnel": "network-transmit-receive-symbolic",
    "ap": "network-wireless-symbolic",
    "phone": "phone-symbolic",
    "proxy": "preferences-system-network-symbolic",
    "maintenance": "applications-system-symbolic",
}

ACTION_KINDS: tuple[str, ...] = ("action", "doctor")


@dataclass(frozen=True)
class Variant:
    """One non-default way to call an action."""

    label: str
    args: tuple[str, ...] = ()
    check: bool = False
    doc: str = ""


@dataclass(frozen=True)
class Action:
    """One script in ../bin and everything the four views say about it."""

    id: str
    group: str = ""
    title: str = ""
    summary: str = ""
    doc: str = ""
    usage: str = ""
    usage_const: str = ""
    module: str = ""
    function: str = ""
    kind: str = "action"
    gui: bool = True
    root: bool = False
    supports_check: bool = False
    supports_yes: bool = False
    destructive: bool = False
    long_running: bool = False
    confirm: str = ""
    variants: tuple[Variant, ...] = ()

    @property
    def action(self) -> bool:
        """True for the entries the GUI and `phone-link run` expose."""
        return self.kind in ACTION_KINDS

    @property
    def needs_confirm(self) -> bool:
        return self.destructive or bool(self.confirm)


SCRIPTS: tuple[Action, ...] = (
    # -- status ----------------------------------------------------
    Action(
        "phone-net-status",
        "status",
        "Overview",
        "Links, routes, resolver, proxy probes, adb transports and phone state.",
        doc="links, routes, resolver, proxy probes, adb transports, phone state",
        usage="usage: phone-net-status",
        module="phone_link.commands.status",
        function="phone_net_status",
    ),

    # Read-only, but its secrets and proxy_request checks read the root-only
    # secrets file and probe through the authenticated proxy, so the run
    # escalates: otherwise every report is incomplete.
    Action(
        "phone-doctor",
        "status",
        "Doctor",
        "Check every runtime condition of the setup. Read-only.",
        doc=(
            "check every runtime condition of the setup (forwarding, AP role and "
            "link/address, adb, phone link, secrets, proxy, the port the laptop uses "
            "against the phone's listeners, tunnel, tether, internet), the APK a repair "
            "would install, the version the installed app reports and the phone SDK, and "
            "whether the source checkout is newer than the installed flake lock; the "
            "`ap_channel` line checks the configured band/channel against the current "
            "regulatory domain without needing the AP up (ok, or warn naming the country "
            "and `phoneLink.ap.country`/`iw reg set`/2.4 GHz; skipped when the AP is off "
            "or external); exit non-zero if a required one is unmet; the adb check "
            "reconnects a phone whose wireless-debugging port changed by reading its "
            "`_adb-tls-connect._tcp` mDNS record, and reports the pinned port first when "
            "the phone answers there; it reports the two Wi-Fi reconnect globals as an "
            "optional line and names `phone-wifi-connect PhoneLink` when the AP is on air "
            "with no station; with `ap.role = \"external\"` it reports the external role, "
            "the laptop's client link and whether the phone holds `proxyHost`, instead of "
            "\"AP is down\"; `--analyze` prints one `fail`/`warn` line with a stable "
            "problem id for scripts; `--json` prints the whole report as one document, "
            "and `--json-stream` prints `section`, `result` and `done` events as NDJSON, "
            "one flushed line each, sharing `--jobs` so a finished check's result arrives "
            "without waiting for the slow ones (with the default one job the order "
            "matches `--json`)"
        ),
        usage="usage: phone-doctor [--check]",
        kind="doctor",
        module="phone_doctor",
        function="main",
        root=True,
    ),

    Action(
        "net-check",
        "status",
        "Internet check",
        "Fetch a fresh URL with curl, Chrome and Nix and report which reach it.",
        doc=(
            "fetch a fresh URL with curl, Chrome and Nix, reporting which of the three "
            "reach the internet"
        ),
        usage="usage: net-check",
        usage_const="USAGE_NET_CHECK",
        module="phone_link.commands.status",
        function="net_check",
    ),

    Action(
        "phone-proxy-check",
        "status",
        "Proxy probe",
        "Request through the proxy on the hotspot and AP addresses.",
        doc=(
            "request through the proxy on the hotspot and AP addresses (needs root for "
            "the secret)"
        ),
        usage="usage: phone-proxy-check",
        module="phone_link.commands.status",
        function="phone_proxy_check",
        root=True,
    ),

    Action(
        "phone-usb-tether-check",
        "status",
        "USB tether check",
        "Report whether tethering is active and HTTPS answers over that route.",
        doc=(
            "report whether USB tethering is active and whether the internet answers over "
            "the host's tether route"
        ),
        usage="usage: phone-usb-tether-check",
        usage_const="USAGE_TETHER_CHECK",
        module="phone_link.commands.status",
        function="phone_usb_tether_check",
    ),

    Action(
        "phone-wifi-concurrency",
        "status",
        "Wi-Fi concurrency",
        "Report whether the phone runs a Wi-Fi client and hotspot at once.",
        doc=(
            "report whether Wi-Fi client and hotspot can run together (STA+AP), "
            "read-only; exit 2 if the phone does not say"
        ),
        usage="usage: phone-wifi-concurrency",
        usage_const="USAGE_CONCURRENCY",
        module="phone_link.commands.status",
        function="phone_wifi_concurrency",
    ),

    # -- tunnel ----------------------------------------------------
    Action(
        "phone-fix-tunnel",
        "tunnel",
        "Start or restart the tunnel",
        "Start phone-tun, or restart it when its route is missing, then wait.",
        doc=(
            "start `phone-tun`, or restart it when its route is missing, and wait for the "
            "route (`--check` reports only)"
        ),
        usage="usage: phone-fix-tunnel [--check]",
        usage_const="USAGE_TUNNEL",
        module="phone_link.commands.tunnel",
        function="phone_fix_tunnel",
        root=True,
        supports_check=True,
    ),

    Action(
        "phone-tunnel-run",
        "tunnel",
        "Run the tunnel in the foreground",
        "Run the built sing-box config until it is stopped.",
        doc="run the built tunnel config in the foreground",
        usage="usage: phone-tunnel-run [--via-adb]",
        module="phone_link.commands.tunnel",
        function="phone_tunnel_run",
        root=True,
        long_running=True,
        confirm="This replaces the managed tunnel with a foreground run.",
        variants=(
            Variant(
                "Upstream through adb reverse",
                ("--via-adb",),
                doc="same, with the upstream reached through `adb reverse`",
            ),
        ),
    ),

    # -- access point ----------------------------------------------
    Action(
        "phone-ap-up",
        "ap",
        "Bring the access point up",
        (
            "Preflight the radio, then activate the phonelink AP profile; with ap.role = "
            "\"external\" this only nudges the phone back over USB."
        ),
        doc=(
            "preflight the radio and the configured channel's regulatory state "
            "(read-only: `iw phy`/`iw reg get`), then `nmcli connection up phonelink`; a "
            "passive-only or disabled channel exits before the supplicant timeout with "
            "the country and the fixes, and a failure while the channel is allowed hints "
            "at a stale wpa_supplicant and `systemctl restart NetworkManager`; with "
            "`ap.fallback.enable` either failure makes one 2.4 GHz attempt at "
            "`ap.fallback.channel`/`channelWidth` instead of leaving no link; with "
            "`ap.role = \"external\"` it says the AP is external, runs no `iw`/`nmcli`, and "
            "only asks the rejoin watchdog to nudge the phone back over USB"
        ),
        usage="usage: phone-ap-up",
        module="phone_link.commands.ap",
        function="phone_ap_up",
        root=True,
    ),

    Action(
        "phone-ap-down",
        "ap",
        "Drop the access point",
        (
            "Stop the AP and rejoin the phone's own hotspot; with an external AP nothing "
            "is stopped."
        ),
        doc=(
            "drop the AP and rejoin the phone's hotspot; `--client` stops the AP and "
            "leaves the radio free for NetworkManager, without joining anything; a "
            "runtime 2.4 GHz fallback is undone while the profile is down, so the next "
            "up tries 5 GHz again; with `ap.role = \"external\"` it is a no-op and says "
            "the external AP stays up"
        ),
        usage="usage: phone-ap-down [--client] [--help]",
        usage_const="USAGE_AP_DOWN",
        module="phone_link.commands.ap",
        function="phone_ap_down",
        root=True,
        destructive=True,
        confirm="The phone leaves the laptop's access point.",
        variants=(
            Variant("Leave Wi-Fi free for a normal network", ("--client",)),
        ),
    ),

    Action(
        "phone-ap-create",
        "ap",
        "Create the AP profile",
        "Build the phonelink profile from the root-only PHONE_AP_PASS secret.",
        doc=(
            "create the `phonelink` AP profile on 5 GHz channel 149 at 80 MHz from the "
            "root-only `PHONE_AP_PASS` secret (`--refresh` rewrites it after a PSK "
            "change, `--check` reports); a no-op with `ap.role = \"external\"` because "
            "there is no local profile to create"
        ),
        usage="usage: phone-ap-create [--refresh] [--check]",
        usage_const="USAGE_AP_CREATE",
        module="phone_link.commands.ap",
        function="phone_ap_create",
        root=True,
        supports_check=True,
        variants=(
            Variant("Rewrite profile and PSK", ("--refresh",)),
        ),
    ),

    Action(
        "phone-ap-delete",
        "ap",
        "Delete the AP profile",
        "Remove the phonelink profile from NetworkManager, down first if active.",
        doc=(
            "delete the `phonelink` AP profile from NetworkManager, bringing it down "
            "first if active (`--check` reports, `--yes` skips the prompt; a declared "
            "profile returns at the next boot); a no-op with `ap.role = \"external\"`"
        ),
        usage="usage: phone-ap-delete [--yes] [--check]",
        usage_const="USAGE_AP_DELETE",
        module="phone_link.commands.ap",
        function="phone_ap_delete",
        root=True,
        supports_check=True,
        supports_yes=True,
        destructive=True,
        confirm="Delete the AP profile? A declared profile comes back at boot.",
    ),

    Action(
        "phone-fix-forwarding",
        "ap",
        "Enable IPv4 forwarding",
        "Set net.ipv4.ip_forward=1 for the running kernel.",
        doc="set `net.ipv4.ip_forward=1` for the running kernel (`--check` reports only)",
        usage="usage: phone-fix-forwarding [--check]",
        usage_const="USAGE_FORWARDING",
        module="phone_link.commands.tunnel",
        function="phone_fix_forwarding",
        root=True,
        supports_check=True,
    ),

    Action(
        "phone-wifi-connect",
        "ap",
        "Join PhoneLink from the phone",
        "Connect the phone's Wi-Fi client to PhoneLink with WPA2 and wait.",
        doc=(
            "join PhoneLink (or another SSID) with WPA2 and wait for the association "
            "(`--check` reports)"
        ),
        usage="usage: phone-wifi-connect [SSID] [--password PASS] [--check]",
        usage_const="USAGE_WIFI_CONNECT",
        module="phone_link.commands.wifi",
        function="phone_wifi_connect",
        root=True,
        supports_check=True,
    ),

    Action(
        "phone-wifi-reconnect",
        "ap",
        "Harden Wi-Fi reconnects",
        "Apply the two Android globals that let the phone rejoin after a long outage.",
        doc=(
            "apply the two Android globals that let the phone rejoin after a long AP "
            "outage (`network_avoid_bad_wifi=0`, `wifi_always_requested=1`); `--check` "
            "only reports and exits 0 when both match"
        ),
        usage="usage: phone-wifi-reconnect [--check]",
        usage_const="USAGE_WIFI_RECONNECT",
        module="phone_link.commands.wifi",
        function="phone_wifi_reconnect",
        supports_check=True,
    ),

    Action(
        "phone-wifi-enable",
        "ap",
        "Enable phone Wi-Fi",
        "Turn the phone's Wi-Fi radio on and wait until Android reports it.",
        doc="turn the phone's Wi-Fi radio on (`--check` reports)",
        usage="usage: phone-wifi-enable [--check]",
        usage_const="USAGE_WIFI_ENABLE",
        module="phone_link.commands.wifi",
        function="phone_wifi_enable",
        supports_check=True,
    ),

    Action(
        "phone-wifi-forget",
        "ap",
        "Forget a saved network",
        "Forget PhoneLink on the phone so the next join starts clean.",
        doc="forget a saved network, default PhoneLink (`--check`, `--yes`)",
        usage="usage: phone-wifi-forget [SSID] [--check] [--yes]",
        usage_const="USAGE_WIFI_FORGET",
        module="phone_link.commands.wifi",
        function="phone_wifi_forget",
        supports_check=True,
        supports_yes=True,
        destructive=True,
        confirm="The phone forgets the saved PhoneLink network.",
    ),

    # -- phone and adb ---------------------------------------------
    Action(
        "phone-adb-wifi",
        "phone",
        "Enable adb over Wi-Fi",
        "Turn on the legacy port or Android 11+ wireless debugging, then connect.",
        doc=(
            "enable adb over Wi-Fi on the phone: legacy `adb tcpip 5555` and Android 11+ "
            "wireless debugging on its random TLS port, then connect (`--legacy`, "
            "`--tls`, `--check`)"
        ),
        usage="usage: phone-adb-wifi [--legacy | --tls] [--check]",
        usage_const="USAGE_ADB_WIFI",
        module="phone_link.commands.adb",
        function="phone_adb_wifi",
        supports_check=True,
        variants=(
            Variant("Legacy TCP port only", ("--legacy",)),
            Variant("Wireless debugging only", ("--tls",)),
        ),
    ),

    Action(
        "adb-wifi-connect",
        "phone",
        "Connect adb over TCP",
        "Connect adb to whichever phone address answers.",
        doc="connect adb to the phone over TCP",
        usage="usage: adb-wifi-connect [--prepare]",
        module="phone_link.commands.adb",
        function="adb_wifi_connect",
        variants=(
            Variant(
                "Prepare over USB first",
                ("--prepare",),
                doc="once over USB: `adb tcpip 5555` (the tether blips)",
            ),
        ),
    ),

    Action(
        "phone-unlock",
        "phone",
        "Unlock the phone",
        "Wake, swipe and enter the PIN from the root-only secrets file.",
        doc=(
            "unlock the lock screen with `PHONE_PIN` from the secrets file (`--check` "
            "only reports locked/unlocked)"
        ),
        usage="usage: phone-unlock [--check]",
        usage_const="USAGE_UNLOCK",
        module="phone_link.commands.device",
        function="phone_unlock",
        root=True,
        supports_check=True,
    ),

    Action(
        "phone-reboot-unlock",
        "phone",
        "Reboot and unlock",
        "Reboot the phone, wait for boot, then unlock it once.",
        doc="reboot the phone, wait for boot, then unlock once (`--yes` skips the prompt)",
        usage="usage: phone-reboot-unlock [--yes]",
        usage_const="USAGE_REBOOT",
        module="phone_link.commands.device",
        function="phone_reboot_unlock",
        root=True,
        supports_yes=True,
        destructive=True,
        long_running=True,
        confirm="Reboot the phone now? adb and the tether drop until it is back.",
    ),

    Action(
        "phone-usb-tether-default",
        "phone",
        "Default USB action to tethering",
        "Set rndis,adb as the USB function and on screen unlock.",
        doc=(
            "make USB tethering the default USB action, keeping adb (`--check` reports "
            "only)"
        ),
        usage="usage: phone-usb-tether-default [--check]",
        usage_const="USAGE_TETHER_DEFAULT",
        module="phone_link.commands.usb",
        function="phone_usb_tether_default",
        supports_check=True,
    ),

    Action(
        "phone-tether-cycle",
        "phone",
        "Cycle USB tethering",
        "Switch USB to MTP, check the internet, then restore the tether.",
        doc=(
            "switch USB to MTP so `net-check` runs with RNDIS off, then lock and unlock "
            "the phone to restore the tether, verify it and report (`--yes` skips the "
            "prompt; needs the PIN, so run with `sudo`)"
        ),
        usage="usage: phone-tether-cycle [--yes]",
        usage_const="USAGE_CYCLE",
        module="phone_link.commands.device",
        function="phone_tether_cycle",
        root=True,
        supports_yes=True,
        destructive=True,
        long_running=True,
        confirm="Lock and unlock the phone to restore the tether?",
    ),

    Action(
        "phone-fix-mobile-data",
        "phone",
        "Enable mobile data",
        "Turn the phone's mobile data on and wait for a default route.",
        doc=(
            "enable the phone's mobile data and wait for a default route (`--check` "
            "reports only)"
        ),
        usage="usage: phone-fix-mobile-data [--check]",
        usage_const="USAGE_MOBILE_DATA",
        module="phone_link.commands.repair",
        function="phone_fix_mobile_data",
        supports_check=True,
    ),

    Action(
        "phone-fix-internet",
        "phone",
        "Restore internet",
        "Try mobile data, USB tethering, then the phone hotspot, verifying HTTPS.",
        doc=(
            "restore internet for the APK download/check by trying mobile data, USB "
            "tethering, then the phone hotspot with the laptop as a client, verifying "
            "HTTPS after each (`--check` reports only)"
        ),
        usage="usage: phone-fix-internet [--check] [--help]",
        usage_const="USAGE_FIX_INTERNET",
        module="phone_link.commands.repair",
        function="phone_fix_internet",
        root=True,
        supports_check=True,
        long_running=True,
    ),

    # -- proxy app -------------------------------------------------
    Action(
        "phone-proxy-install",
        "proxy",
        "Install the proxy app",
        "Install or update the proxy APK over adb.",
        doc=(
            "install/update the proxy app \u2014 with no argument the newest signed release of "
            "`MBanucu/phone-link-proxy` (`PHONE_PROXY_REPO` overrides), checksum checked, "
            "unless an APK is named; `--release [TAG]` takes a named release instead, "
            "`--build` names the app's repository and refuses (this checkout no longer "
            "builds it), `--fdroid` fetches the legacy vendored app instead, "
            "`--replace-signer` exports the saved proxies first (`phone-proxy-export`), "
            "uninstalls and installs, then imports them back and starts/verifies the "
            "proxy that was in use \u2014 an app that cannot export is not uninstalled, and "
            "for the vendored app the old loss-on-uninstall still applies; `--pull` "
            "copies the installed APK off the phone, `--status` reports the version; for "
            "`org.phonelink.proxy` it also grants `WRITE_SECURE_SETTINGS` and the battery "
            "allowlist, so the app can turn wireless debugging back on itself"
        ),
        usage="usage: phone-proxy-install [APK...]",
        usage_const="USAGE_INSTALL",
        module="phone_link.commands.install",
        function="phone_proxy_install",
        supports_check=True,
        variants=(
            Variant("Download from F-Droid", ("--fdroid",)),
            Variant("Only report the installed version", ("--status",)),
        ),
    ),

    Action(
        "phone-proxy-uninstall",
        "proxy",
        "Uninstall the proxy app",
        "Remove the proxy app; the tunnel falls back to the normal route.",
        doc=(
            "remove the proxy app (`--check` previews, `--keep-data` keeps app data, "
            "`--yes` skips the prompt)"
        ),
        usage="usage: phone-proxy-uninstall [--yes] [--keep-data] [--check]",
        usage_const="USAGE_UNINSTALL",
        module="phone_link.commands.install",
        function="phone_proxy_uninstall",
        supports_check=True,
        supports_yes=True,
        destructive=True,
        confirm="Uninstall the proxy app from the phone?",
    ),

    Action(
        "phone-proxy-setup",
        "proxy",
        "Configure the proxy app",
        "Write port, credentials and auto-start through the app's settings screen.",
        doc=(
            "the first-run path: start the proxy through the app's own intent with the "
            "port, credentials and auto-start as extras, then verify a request through "
            "the listener; `--max-connections N` also sends the SOCKS connection ceiling "
            "(16..1024, left out the app keeps its saved value \u2014 256 on a fresh install), "
            "and `--check` reports the settings, including the ceiling when the app "
            "prints it, and checks the request"
        ),
        usage="usage: phone-proxy-setup [--check] [--port N] [--user NAME] [--no-auto-start]",
        usage_const="USAGE_SETUP",
        module="phone_link.commands.proxy",
        function="phone_proxy_setup",
        root=True,
        supports_check=True,
        long_running=True,
    ),

    Action(
        "phone-proxy-switch",
        "proxy",
        "Choose the proxy port",
        (
            "Make the tunnel and relay use a port the phone listens on, starting a saved "
            "proxy if needed."
        ),
        doc=(
            "make the laptop use a port the phone listens on: `--profile NAME` starts "
            "that saved proxy when it is not running and `--port N` requires the phone to "
            "be listening there, a request through the new port has to answer 200 before "
            "the laptop changes, then the port is written to "
            "`/run/phone-link/proxy-port`, `phone-tun` and the relay are restarted if "
            "they were running, and the phone's listener on the old port is stopped last "
            "(`--check` compares the two ports, `--list` prints the phone's saved proxies, "
            "listeners and `service` state as JSON for the panel, with `contract` as the "
            "app's contract version (null when the app does not say); a stopped service "
            "uses the app's non-secret saved index instead of reporting two empty lists)"
        ),
        usage="usage: phone-proxy-switch [--check | --list] (--port N | --profile NAME)",
        usage_const="USAGE_SWITCH",
        module="phone_link.commands.proxy",
        function="phone_proxy_switch",
        root=True,
        supports_check=True,
        long_running=True,
    ),

    Action(
        "phone-proxy-start",
        "proxy",
        "Start the proxy",
        "Unlock the phone, open the app and tap Start, then wait for it.",
        doc=(
            "start the proxy through the app's own intent and wait until the service says "
            "it is listening (`--check` only reports; a fresh install with no saved proxy "
            "says to run `phone-proxy-setup` instead of sending a bare START)"
        ),
        usage="usage: phone-proxy-start [--check]",
        usage_const="USAGE_START",
        module="phone_link.commands.proxy",
        function="phone_proxy_start",
        root=True,
        supports_check=True,
    ),

    Action(
        "phone-proxy-stop",
        "proxy",
        "Stop the proxy",
        "Unlock the phone, open the app and tap Stop, then wait for it.",
        doc=(
            "stop the proxy through the app's own intent and wait until the service is "
            "gone (`--check` only reports)"
        ),
        usage="usage: phone-proxy-stop [--check]",
        usage_const="USAGE_STOP",
        module="phone_link.commands.proxy",
        function="phone_proxy_stop",
        root=True,
        supports_check=True,
    ),

    Action(
        "phone-proxy-export",
        "proxy",
        "Back up the saved proxies",
        "Pull every saved proxy into a root-only file beside the secrets.",
        doc=(
            "pull every saved proxy with its port, SSID, credentials and switches off the "
            "phone over a one-shot loopback socket and write it root-only (mode 0600) "
            "beside the secrets (`PHONE_PROXY_BACKUP`, default "
            "`/etc/nixos/phone-link-proxies.json`; `--out FILE` overrides) \u2014 the same "
            "`ProfileDocument` JSON the app's menu exports, never a file on the phone; "
            "the screen must be on and the phone unlocked"
        ),
        usage="usage: phone-proxy-export [--out FILE]",
        usage_const="USAGE_EXPORT",
        module="phone_link.commands.proxy",
        function="phone_proxy_export",
        root=True,
    ),

    Action(
        "phone-proxy-import",
        "proxy",
        "Restore the saved proxies",
        "Write a saved-proxy backup back into the app, replacing what is there.",
        doc=(
            "write a `phone-proxy-export` backup back into the app over the same one-shot "
            "socket, replacing every saved proxy; the app validates the whole document "
            "first, so a malformed file changes nothing; the screen must be on and the "
            "phone unlocked"
        ),
        usage="usage: phone-proxy-import FILE",
        usage_const="USAGE_IMPORT",
        module="phone_link.commands.proxy",
        function="phone_proxy_import",
        root=True,
    ),

    Action(
        "phone-proxy-data-clear",
        "proxy",
        "Clear proxy app data",
        "Reset the app to port 1080 with no auth; the proxy stops.",
        doc=(
            "wipe the proxy app's data, back to port 1080 with no auth (`--check` "
            "previews, `--yes` skips the prompt)"
        ),
        usage="usage: phone-proxy-data-clear [--yes] [--check]",
        usage_const="USAGE_DATA_CLEAR",
        module="phone_link.commands.install",
        function="phone_proxy_data_clear",
        supports_check=True,
        supports_yes=True,
        destructive=True,
        confirm="Clear the proxy app's data? Port and credentials are lost.",
    ),

    Action(
        "phone-proxy-boot",
        "proxy",
        "Make the app restart at boot",
        "Allowlist it, grant background location and turn auto_start on.",
        doc=(
            "make the proxy app come back after a reboot: add it to the device-idle "
            "allowlist, grant the location and notification permissions the SSID read and "
            "boot start need, turn `auto_start` on, and check that the installed build "
            "can start before the first unlock (direct-boot flag and a "
            "`LOCKED_BOOT_COMPLETED` receiver); the service itself is `specialUse`, not a "
            "`location` one (`--check` names every missing input and says which one needs "
            "a reinstall). DokeOS Auto Start Management is a separate gate behind a "
            "signature permission: it names the screen and the app's dated \"likely "
            "blocked\" fact, and never claims the gate is open"
        ),
        usage="usage: phone-proxy-boot [--check]",
        usage_const="USAGE_BOOT",
        module="phone_link.commands.proxy",
        function="phone_proxy_boot",
        supports_check=True,
    ),

    Action(
        "phone-proxy-battery-whitelist",
        "proxy",
        "Exempt the proxy from Doze",
        "Add the app to the device-idle whitelist so Doze cannot kill it.",
        doc=(
            "add the proxy app to the device-idle (Doze) whitelist so the proxy is not "
            "killed with the screen off (`--check` only reports)"
        ),
        usage="usage: phone-proxy-battery-whitelist [--check]",
        usage_const="USAGE_BATTERY",
        module="phone_link.commands.proxy",
        function="phone_proxy_battery_whitelist",
        supports_check=True,
    ),

    # -- maintenance -----------------------------------------------
    Action(
        "phone-doctor-fix",
        "maintenance",
        "Repair reported problems",
        "Run the fix script for each problem the doctor reports, then re-check.",
        doc=(
            "list the fixes for the problems `phone-doctor --analyze` reports, run one "
            "dedicated script per problem in dependency order, then re-check (`--yes` "
            "skips the prompt, `--dry-run` only lists, `--required` leaves warnings "
            "alone, `--which-doctor` prints the `phone-doctor` it reads \u2014 the one beside "
            "the checkout unless `PHONE_DOCTOR` says otherwise; run with `sudo`)"
        ),
        usage="usage: phone-doctor-fix [--yes] [--dry-run] [--required] [--which-doctor]",
        usage_const="USAGE",
        module="phone_link.commands.doctor_fix",
        function="phone_doctor_fix",
        root=True,
        supports_check=True,
        supports_yes=True,
        long_running=True,
        confirm="Apply the fixes the doctor reports?",
        variants=(
            Variant("Only required problems", ("--required",)),
        ),
    ),

    Action(
        "phone-fix-apk",
        "maintenance",
        "Stock the ambulance APK",
        "Cache the proxy APK so the app can be reinstalled without a network.",
        doc=(
            "stock the ambulance box: copy the app APK the cache or `PHONE_PROXY_APK` "
            "names into `/var/cache/phone-link` so a repair on a machine without a "
            "download can still reinstall the app; `--releases [N]` also keeps the APKs "
            "of the newest N releases (5 by default) as a repair kit of several versions, "
            "each checked against its `.sha256` and named after its tag, older ones "
            "pruned past three times N (`--refresh` replaces the copy and refreshes the "
            "kit, `--check` lists the box)"
        ),
        usage="usage: phone-fix-apk [--refresh] [--releases [N]] [--check]",
        usage_const="USAGE_FIX_APK",
        module="phone_link.commands.repair",
        function="phone_fix_apk",
        root=True,
        supports_check=True,
        long_running=True,
        variants=(
            Variant("Always download the newest", ("--refresh",)),
        ),
    ),

    Action(
        "phone-link-uninstall",
        "maintenance",
        "Remove runtime state",
        "Delete the AP profile and APK caches after unwiring the module.",
        doc=(
            "remove the AP profile and APK caches after unwiring the module (`--check`, "
            "`--yes`, `--keep-cache`); straight from the checkout"
        ),
        usage="usage: phone-link-uninstall [--yes] [--check] [--keep-cache]",
        usage_const="USAGE_UNINSTALL",
        module="phone_link.commands.maintenance",
        function="phone_link_uninstall",
        root=True,
        supports_check=True,
        supports_yes=True,
        destructive=True,
        confirm="Remove the AP profile and the cached APKs?",
        variants=(
            Variant("Keep the APK caches", ("--keep-cache",)),
        ),
    ),

    # -- entry points that are not actions ----------------------------
    # Listed explicitly so the shims, the package and the registry check all
    # know about them: `phone-link` is the shared CLI, `phone-link-gui` the
    # panel, and `phone-link-gui-screenshots` the release-only capture tool,
    # whose body is a shell script and is not generated.
    Action(
        "phone-link",
        summary="List, run and check the shared actions from the shell.",
        module="phone_link.cli",
        function="main",
        kind="cli",
        gui=False,
    ),
    Action(
        "phone-link-gui",
        summary="The GTK4/libadwaita control panel for the same actions.",
        module="phone_link_gui.app",
        function="main",
        kind="gui",
        gui=False,
    ),
    Action(
        "phone-link-gui-screenshots",
        summary="Capture the panel's states as PNGs for release notes.",
        kind="tool",
        gui=False,
    ),
)

# The entries the GUI, `phone-link list` and `check-registry` expose. The
# CLI, the panel and the screenshot tool are shims whose body is not a
# commands function, so they are packed and generated but are not actions.
ACTIONS: tuple[Action, ...] = tuple(script for script in SCRIPTS if script.action)

SCRIPT_BY_ID: dict[str, Action] = {script.id: script for script in SCRIPTS}
BY_ID: dict[str, Action] = {action.id: action for action in ACTIONS}


def actions_in(group: str) -> list[Action]:
    return [action for action in ACTIONS if action.group == group and action.gui]


def gui_actions() -> list[Action]:
    """The actions the panel renders: visibility is part of the table."""
    return [action for action in ACTIONS if action.gui]


def binary(action: Action) -> str:
    """The script's path: PATH first, then the checkout next to this package."""
    found = shutil.which(action.id)
    if found:
        return found
    root = Path(__file__).resolve().parents[3]
    candidate = root / "bin" / action.id
    return str(candidate) if candidate.is_file() else action.id


def doctor_bin() -> str | None:
    """The doctor to read problems from.

    The doctor beside this package wins over the one on PATH: a checkout's
    fixer run against the deployed doctor fixes what an older set of checks saw
    — or nothing at all — which reads as "the doctor is broken". A store
    install keeps every script under share/phone-link/bin, so this also finds
    its own doctor when PATH has none (a flake check, the GUI).
    """
    override = os.environ.get("PHONE_DOCTOR")
    if override:
        return override
    root = Path(__file__).resolve().parents[3]
    candidate = root / "bin" / "phone-doctor"
    if candidate.is_file() and os.access(candidate, os.X_OK):
        return str(candidate)
    return shutil.which("phone-doctor")


def plan(
    action: Action,
    *,
    args: tuple[str, ...] = (),
    check: bool = False,
    assume_yes: bool = False,
    escalate: bool | None = None,
    env: dict[str, str] | None = None,
) -> list[str]:
    """The argv for one run, including the flags and escalation it implies."""
    argv = [binary(action), *args]
    if check:
        if not action.supports_check:
            raise ValueError(f"{action.id} has no --check")
        argv.append("--check")
    if assume_yes and action.supports_yes and not check:
        argv.append("--yes")
    if escalate is None:
        escalate = action.root
    if escalate and os.geteuid() != 0:
        prefix = escalation_prefix(env)
        if prefix:
            argv = [*prefix, *phone_env(env), *argv]
    return argv


def phone_env(env: dict[str, str] | None = None) -> list[str]:
    """The PHONE_* overrides the scripts document, as `env` arguments."""
    values = env if env is not None else os.environ
    return [
        f"{key}={value}"
        for key, value in sorted(values.items())
        if key.startswith("PHONE_")
    ]


def escalation_prefix(env: dict[str, str] | None = None) -> list[str]:
    """How to become root, ending in `env` for the PHONE_* overrides.

    sudo comes first because it remembers an authentication for a few minutes:
    the first root action asks once (through SUDO_ASKPASS in the GUI) and the
    following ones run with `-n` and no dialog. pkexec keeps no authorization
    at all (its policy is auth_admin), so it only serves machines without sudo.
    """
    values = env if env is not None else os.environ
    sudo = shutil.which("sudo")
    if sudo:
        cached = subprocess.run(
            [sudo, "-n", "true"], capture_output=True, check=False
        )
        if cached.returncode == 0:
            return [sudo, "-n", "env"]
        askpass = values.get("SUDO_ASKPASS")
        if askpass and os.access(askpass, os.X_OK):
            return [sudo, "-A", "env"]
    pkexec = shutil.which("pkexec")
    if pkexec:
        return [pkexec, "env"]
    return []


def _module_problems(action: Action) -> list[str]:
    """The module:function, usage constant and body agree with this table."""
    problems: list[str] = []
    if action.kind == "tool":
        if action.module or action.function:
            problems.append(f"{action.id}: a tool has no Python module")
        return problems
    if not action.module or not action.function:
        problems.append(f"{action.id}: no module:function")
        return problems
    if action.kind == "gui":
        # The panel's module imports GTK, which only the gui-registry check
        # has; the registry still proves the module exists.
        try:
            spec = importlib.util.find_spec(action.module)
        except Exception as exc:
            spec = None
            problems.append(f"{action.id}: cannot find {action.module}: {exc}")
        if spec is None and not problems:
            problems.append(f"{action.id}: cannot find {action.module}")
        return problems
    try:
        module = importlib.import_module(action.module)
    except Exception as exc:  # a missing module is a registry problem, not a crash
        problems.append(f"{action.id}: cannot import {action.module}: {exc}")
        return problems
    handler = getattr(module, action.function, None)
    if not callable(handler):
        problems.append(
            f"{action.id}: {action.module} has no function {action.function}"
        )
    if action.usage_const:
        text = getattr(module, action.usage_const, "")
        first = text.splitlines()[0] if text else ""
        if first != action.usage:
            problems.append(
                f"{action.id}: usage is {action.usage!r}, "
                f"{action.module}.{action.usage_const} says {first!r}"
            )
    elif action.usage and not action.usage.startswith("usage: "):
        problems.append(f"{action.id}: usage must start with 'usage: '")
    return problems


def validate(expected: tuple[str, ...] | list[str] = ()) -> list[str]:
    """Problems with the registry, for the flake's checks and `check-registry`."""
    problems: list[str] = []
    ids = [script.id for script in SCRIPTS]
    duplicates = sorted({name for name in ids if ids.count(name) > 1})
    if duplicates:
        problems.append("duplicate ids: " + ", ".join(duplicates))

    kinds = {"action", "doctor", "cli", "gui", "tool"}
    group_ids = {group for group, _ in GROUPS}
    for script in SCRIPTS:
        if script.kind not in kinds:
            problems.append(f"{script.id}: unknown kind {script.kind}")
        if script.kind in ACTION_KINDS:
            if script.group not in group_ids:
                problems.append(f"{script.id}: unknown group {script.group}")
        elif script.gui or script.group:
            problems.append(f"{script.id}: a {script.kind} entry is not a GUI action")
        problems.extend(_module_problems(script))

    for action in ACTIONS:
        program = binary(action)
        if not os.access(program, os.X_OK):
            problems.append(f"{action.id}: not executable ({program})")
        for variant in action.variants:
            if variant.check and not action.supports_check:
                problems.append(f"{action.id}: variant {variant.label} needs --check")

    # The four entry points that are not `phone_link.commands` functions stay
    # explicit: the CLI, the panel, the release-only screenshot tool and the
    # doctor package. A missing one is a silently uninstalled script.
    for name, kind in (
        ("phone-doctor", "doctor"),
        ("phone-link", "cli"),
        ("phone-link-gui", "gui"),
        ("phone-link-gui-screenshots", "tool"),
    ):
        script = SCRIPT_BY_ID.get(name)
        if script is None:
            problems.append(f"missing entry point: {name}")
        elif script.kind != kind:
            problems.append(f"{name}: expected kind {kind}, found {script.kind}")

    # The checked-in shims, commands/__init__.py and the docs table are
    # generated from this table; the same check runs in the flake against the
    # source tree. A package install has no docs/ and no source bin/, so the
    # generation check is skipped there.
    from . import registry_gen

    problems.extend(registry_gen.check(Path(__file__).resolve().parents[3]))

    if expected:
        action_ids = [action.id for action in ACTIONS]
        missing = sorted(set(expected) - set(action_ids))
        extra = sorted(set(action_ids) - set(expected))
        if missing:
            problems.append("no action for: " + ", ".join(missing))
        if extra:
            problems.append("action without a script: " + ", ".join(extra))
    return problems
