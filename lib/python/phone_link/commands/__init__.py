"""The bin/ commands that live in Python, one function per script.

`bin/phone-net-status` and its siblings are shims that hand the script's name
to `python3 -m phone_link.commands`, so the name stays the contract: the
registry, the Nix wrappers and the tests all address the scripts, not modules.
"""

from __future__ import annotations

import sys

from . import device, doctor_fix, maintenance, network, phone, proxy, status

COMMANDS = {
    "phone-net-status": status.phone_net_status,
    "net-check": status.net_check,
    "phone-proxy-check": status.phone_proxy_check,
    "phone-usb-tether-check": status.phone_usb_tether_check,
    "phone-wifi-concurrency": status.phone_wifi_concurrency,
    "phone-fix-mobile-data": phone.phone_fix_mobile_data,
    "phone-wifi-enable": phone.phone_wifi_enable,
    "phone-wifi-forget": phone.phone_wifi_forget,
    "phone-usb-tether-default": phone.phone_usb_tether_default,
    "phone-proxy-battery-whitelist": phone.phone_proxy_battery_whitelist,
    "phone-proxy-data-clear": phone.phone_proxy_data_clear,
    "phone-proxy-uninstall": phone.phone_proxy_uninstall,
    "phone-proxy-install": phone.phone_proxy_install,
    "phone-adb-wifi": phone.phone_adb_wifi,
    "adb-wifi-connect": phone.adb_wifi_connect,
    "phone-fix-forwarding": network.phone_fix_forwarding,
    "phone-fix-tunnel": network.phone_fix_tunnel,
    "phone-tunnel-run": network.phone_tunnel_run,
    "phone-ap-up": network.phone_ap_up,
    "phone-ap-down": network.phone_ap_down,
    "phone-ap-create": network.phone_ap_create,
    "phone-ap-delete": network.phone_ap_delete,
    "phone-wifi-connect": network.phone_wifi_connect,
    "phone-fix-internet": network.phone_fix_internet,
    "phone-fix-apk": network.phone_fix_apk,
    "phone-link-uninstall": maintenance.phone_link_uninstall,
    "phone-unlock": device.phone_unlock,
    "phone-reboot-unlock": device.phone_reboot_unlock,
    "phone-tether-cycle": device.phone_tether_cycle,
    "phone-proxy-start": proxy.phone_proxy_start,
    "phone-proxy-stop": proxy.phone_proxy_stop,
    "phone-proxy-setup": proxy.phone_proxy_setup,
    "phone-doctor-fix": doctor_fix.phone_doctor_fix,
}

USAGE = "usage: phone_link.commands <command> [options]\n\ncommands:\n" + "".join(
    f"  {name}\n" for name in COMMANDS
)


def main(argv: list[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if not args:
        print(USAGE, end="", file=sys.stderr)
        return 2
    command, rest = args[0], args[1:]
    handler = COMMANDS.get(command)
    if handler is None:
        print(f"error: unknown command: {command}", file=sys.stderr)
        return 2
    return handler(rest)
