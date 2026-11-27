"""Read whether the laptop access point is on, from text another tool printed.

The Status page probes without root: NetworkManager's active connections name
the AP profile while it is up, and `iw dev IFACE info` says `type AP` even when
NetworkManager does not (or cannot) report the connection. Keeping the parsing
here lets a hermetic test cover both answers without a display or a radio.
"""

from __future__ import annotations


def ap_is_on(active_connections: str, iw_info: str, connection: str) -> bool:
    """True when the AP profile is active or the interface is in AP mode.

    `active_connections` is `nmcli -t -f NAME,DEVICE con show --active`, one
    `NAME:DEVICE` per line; `iw_info` is `iw dev IFACE info`. An unreadable
    answer is just an empty string, which means "not on" only when both are.
    """
    for line in active_connections.splitlines():
        name, _, _device = line.partition(":")
        if name == connection:
            return True
    for line in iw_info.splitlines():
        if line.split() == ["type", "AP"]:
            return True
    return False
