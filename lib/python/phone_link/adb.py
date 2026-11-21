"""adb against the phone's *current* transport, rediscovered through mDNS.

Wireless debugging picks a new port on every boot, so a serial a command
resolved earlier (`192.168.77.232:44895`) stops working the moment the phone
restarts, and `adb devices` may list nothing at all. The port is not lost,
though: adbd advertises it as an `_adb-tls-connect._tcp` record, which
`avahi-browse -rtp` prints in one line and which takes about a second to read —
far less than the connect scan the alternative would need.

Every adb invocation goes through `prepare()` (before it runs) and `retry()`
(after it failed), so a rotated port is never fatal:

* a command whose target is still attached runs unchanged and costs one
  `adb devices` at most, because only network serials can move;
* a command aimed at a serial that is gone is retargeted at the advertised
  endpoint, once `adb connect` accepts it;
* `phone_serial()` and the doctor resolve a serial through `discover()` first,
  so "no phone attached" is only reported when the phone really is absent.

A phone whose wireless-adb-keeper app pinned adbd to a fixed port answers on
that port at every reboot, so `pinned_endpoint()` is asked first and costs one
`adb devices` when it works: no browse, no scan, and a serial that survives the
reboot unchanged. mDNS is the fallback for a phone that randomises its port.

`PHONE_ADB_MDNS=0` turns the lookup off, for a machine whose mDNS cannot be
trusted or a test that must not see a real phone.
"""

from __future__ import annotations

import os
import subprocess
import time
from typing import Sequence

from . import settings

SERVICE = "_adb-tls-connect._tcp"

# The port phone-link's own app pins adbd to. Only a hint: on a phone without
# it nothing answers here and the mDNS record still decides.
PINNED_PORT = settings.PHONE_ADB_PORT

# Commands that talk to the adb server or to a network address rather than to
# one device. Retargeting them would change what the caller asked for.
SERVER_COMMANDS = frozenset(
    {
        "connect",
        "disconnect",
        "devices",
        "kill-server",
        "start-server",
        "version",
        "mdns",
        "pair",
    }
)

# Options that take a value, so the token after them is not the subcommand.
_TAKES_VALUE = ("-s", "-t", "-H", "-P", "-L")

# One lookup answers for a few seconds: a command that runs ten adb calls must
# not run ten browses, while the next command after a reboot must look again.
LOOKUP_SECONDS = 5.0

_address: str | None = None
_lookup_at = 0.0


def enabled() -> bool:
    return os.environ.get("PHONE_ADB_MDNS", "1") != "0"


def _run(
    argv: Sequence[str], *, timeout: float = 15.0
) -> subprocess.CompletedProcess[str] | None:
    try:
        return subprocess.run(
            list(argv),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=timeout,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None


def devices() -> dict[str, str]:
    """Every serial adb knows, with the state it reports (device, offline…)."""
    done = _run(["adb", "devices"])
    if done is None or done.returncode != 0:
        return {}
    states: dict[str, str] = {}
    for line in done.stdout.splitlines()[1:]:
        fields = line.split()
        if len(fields) >= 2:
            states[fields[0]] = fields[1]
    return states


def attached(serial: str) -> bool:
    return devices().get(serial) == "device"


def mdns_addresses(*, timeout: float = 5.0) -> list[str]:
    """The endpoints adbd currently advertises, `ip:port` each.

    `avahi-browse -rtp` prints one line per service:
    `=;iface;IPv4;name;_adb-tls-connect._tcp;local;host;address;port;txt`.
    The record is the only place the new port appears before adb knows it.
    """
    done = _run(["avahi-browse", "-rtp", SERVICE], timeout=timeout)
    if done is None:
        return []
    addresses = []
    for line in done.stdout.splitlines():
        fields = line.split(";")
        if len(fields) >= 9 and fields[0] == "=" and fields[2] == "IPv4":
            address, port = fields[7], fields[8]
            if address and port.isdigit():
                addresses.append(f"{address}:{port}")
    return addresses


def attach(address: str) -> bool:
    """Whether adb reaches `address`, connecting to it first when it does not."""
    if attached(address):
        return True
    _run(["adb", "connect", address], timeout=20.0)
    return attached(address)


def pinned_addresses(hint: str | None = None) -> list[str]:
    """The pinned port on the addresses this phone can hold, best guess first.

    With a hint its host wins, because several phones on one network each pin
    the same port and only that host is the one the caller meant. Without one,
    the two addresses this checkout already knows for the phone are tried: the
    AP it joins and its own hotspot.
    """
    hosts: list[str] = []
    if hint and ":" in hint:
        hosts.append(hint.rsplit(":", 1)[0])
    else:
        hosts += [settings.PHONE_AP_IP, settings.PHONE_HOTSPOT_IP]
    addresses: list[str] = []
    for host in hosts:
        if not host or host in ("", "0.0.0.0"):
            continue
        address = f"{host}:{PINNED_PORT}"
        if address not in addresses:
            addresses.append(address)
    return addresses


def pinned_endpoint(hint: str | None = None) -> str | None:
    """The pinned port when it answers, else None — no mDNS involved."""
    if not enabled():
        return None
    for address in pinned_addresses(hint):
        if attach(address):
            return address
    return None


def discover(hint: str | None = None, *, force: bool = False) -> str | None:
    """Connect to the pinned port or an advertised endpoint and return it.

    `hint` is the serial the caller wanted; its host part wins, because a
    reboot changes the port, not the address — for the pinned probe as much as
    for a phone that advertises several endpoints.
    """
    global _address, _lookup_at
    if not enabled():
        return None
    now = time.monotonic()
    if not force and now - _lookup_at < LOOKUP_SECONDS:
        return _address
    _lookup_at = now
    _address = None

    # A pinned adbd needs no browse and no scan: one connect at most, and the
    # serial it returns is still the right one after the next reboot.
    pinned = pinned_endpoint(hint)
    if pinned:
        _address = pinned
        return _address

    addresses = mdns_addresses()
    if hint and ":" in hint:
        host = hint.rsplit(":", 1)[0]
        addresses.sort(key=lambda address: not address.startswith(host + ":"))
    for address in addresses:
        if not attached(address):
            _run(["adb", "connect", address], timeout=20.0)
        if attached(address):
            _address = address
            break
    return _address


def target(argv: Sequence[str]) -> tuple[int, str] | None:
    """The `-s` target of a command, as (index, serial)."""
    for index, value in enumerate(argv):
        if value == "-s" and index + 1 < len(argv):
            return index + 1, argv[index + 1]
        if len(value) > 2 and value.startswith("-s"):
            return index, value[2:]
    return None


def subcommand(argv: Sequence[str]) -> str:
    index = 1
    while index < len(argv):
        value = argv[index]
        if value in _TAKES_VALUE:
            index += 2
            continue
        if value.startswith("-"):
            index += 1
            continue
        return value
    return ""


def prepare(argv: Sequence[str]) -> list[str]:
    """The same command aimed at a serial that is still attached.

    Only a network serial can be stale — a USB one survives a reboot — so the
    cost for the USB case is one string check and no adb call at all.
    """
    argv = list(argv)
    if not enabled() or not argv or argv[0] != "adb":
        return argv
    if subcommand(argv) in SERVER_COMMANDS:
        return argv
    found = target(argv)
    if found is None:
        return argv
    index, serial = found
    if ":" not in serial or attached(serial):
        return argv
    address = discover(hint=serial)
    if address is None:
        return argv
    argv[index] = address
    return argv


def retry(argv: Sequence[str]) -> list[str] | None:
    """A command that failed on a vanished transport, aimed at the new one."""
    argv = list(argv)
    if not enabled() or not argv or argv[0] != "adb":
        return None
    if subcommand(argv) in SERVER_COMMANDS:
        return None
    found = target(argv)
    if found is None:
        return None
    index, serial = found
    if ":" not in serial or attached(serial):
        return None
    address = discover(hint=serial, force=True)
    if address is None or address == serial:
        return None
    argv[index] = address
    return argv
