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

USB and Wi-Fi are two transports of the same phone, not two phones. When adb
lists more than one attached transport, `resolve_serial()` groups them by
hardware identity (`ro.serialno`, or the `adb devices -l` descriptors when the
property is empty) and picks one member of the group. The ambiguity error is
kept for two genuinely different phones.

`PHONE_ADB_MDNS=0` turns the lookup off, for a machine whose mDNS cannot be
trusted or a test that must not see a real phone.
"""

from __future__ import annotations

import os
import subprocess
import time
from dataclasses import dataclass
from typing import Mapping, Sequence

from . import settings

SERVICE = "_adb-tls-connect._tcp"


class SerialError(RuntimeError):
    """The one target device cannot be chosen without the operator's help.

    Two genuinely different phones attached at once are ambiguous; a command
    that changes the phone must stop and say so rather than let adb pick one.
    `PHONE_SERIAL` is the documented answer. Two transports of the same phone
    are not this error: they are grouped and one is chosen deliberately.
    """


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


@dataclass(frozen=True)
class Device:
    """One adb transport, as `adb devices -l` describes it."""

    serial: str
    state: str
    product: str = ""
    model: str = ""
    device: str = ""


def listing() -> list[Device]:
    """Every adb transport with the descriptors `adb devices -l` adds.

    `adb devices` is enough for a state, but not for deciding whether two
    transports are the same hardware: the product/model/device triple is the
    fallback identity when the phone will not answer `getprop ro.serialno`.
    """
    done = _run(["adb", "devices", "-l"])
    if done is None or done.returncode != 0:
        return []
    found: list[Device] = []
    for line in done.stdout.splitlines()[1:]:
        fields = line.split()
        if len(fields) < 2:
            continue
        attributes: dict[str, str] = {}
        for field in fields[2:]:
            key, separator, value = field.partition(":")
            if separator:
                attributes[key] = value
        found.append(
            Device(
                serial=fields[0],
                state=fields[1],
                product=attributes.get("product", ""),
                model=attributes.get("model", ""),
                device=attributes.get("device", ""),
            )
        )
    return found


def hardware_serial(serial: str) -> str:
    """`ro.serialno` for one transport, or "" when it will not say.

    A network transport can be attached while the phone refuses a shell
    command (a just-connected port, a locked screen), and a USB transport can
    be listed by an adb server that has not finished opening it. The identity
    fallback exists for both, so a failure here is not an error.
    """
    done = _run(
        ["adb", "-s", serial, "shell", "getprop", "ro.serialno"], timeout=3.0
    )
    if done is None or done.returncode != 0:
        return ""
    return done.stdout.strip()


def identity(device: Device) -> str:
    """What makes two transports the same phone.

    The hardware serial is the strong key: two phones of the same model have
    the same product/model/device triple but never the same `ro.serialno`.
    The descriptor is what remains when the property is empty; the serial
    itself is the last resort, so two unknown transports are not merged.
    """
    serial = hardware_serial(device.serial)
    if serial:
        return f"serial:{serial}"
    descriptor = "/".join(
        value for value in (device.model, device.device, device.product) if value
    )
    if descriptor:
        return f"descriptor:{descriptor}"
    return f"transport:{device.serial}"


def _preferred_hosts(values: Mapping[str, str]) -> list[str]:
    """The addresses whose network transport should win, in order."""
    hosts: list[str] = []
    for name in ("PHONE_PROXY_HOST", "PHONE_AP_IP"):
        value = (values.get(name) or "").strip()
        if value:
            host = value.rsplit(":", 1)[0] if ":" in value else value
            if host and host not in hosts:
                hosts.append(host)
    for value in (settings.PHONE_PROXY_HOST, settings.PHONE_AP_IP):
        host = value.rsplit(":", 1)[0] if ":" in value else value
        if host and host not in hosts:
            hosts.append(host)
    return hosts


def _host(serial: str) -> str:
    return serial.rsplit(":", 1)[0] if ":" in serial else serial


def _choose_transport(serials: Sequence[str], values: Mapping[str, str]) -> str:
    """One transport from the group that is the same phone.

    USB first: a USB serial survives a reboot while a network port is picked
    afresh by wireless debugging. Between network transports the configured
    host wins, because that is the address the rest of phone-link talks to.
    """
    usb = sorted(serial for serial in serials if ":" not in serial)
    if usb:
        return usb[0]
    for host in _preferred_hosts(values):
        matching = sorted(serial for serial in serials if _host(serial) == host)
        if matching:
            return matching[0]
    return sorted(serials)[0]


def resolve_serial(
    env: Mapping[str, str] | None = None, *, network_only: bool = False
) -> str | None:
    """The one adb serial every command should target.

    The order is the documented one: `PHONE_SERIAL`, then the only attached
    phone, else `None` (or `SerialError` when more than one *phone* is
    attached). USB and Wi-Fi transports of the same phone are grouped by
    hardware identity and one of them is chosen deterministically, so the
    normal wireless-debugging state is not ambiguous.

    `network_only` restricts both the automatic choice and the grouping to
    network transports, which is what the status display means by "adb
    wireless"; an explicit `PHONE_SERIAL` is returned either way because the
    operator named it.

    A phone that rebooted is still on the network and still advertises its new
    wireless-debugging port, so an empty `adb devices` is retried through the
    mDNS record before the caller reports that nothing is attached.
    """
    values = os.environ if env is None else env
    explicit = (values.get("PHONE_SERIAL") or "").strip()
    if explicit:
        return explicit

    def choose() -> str | None:
        found = listing()
        states = {device.serial: device.state for device in found}
        if not states:
            # An older adb or a failed `-l` still gives the states; grouping
            # falls back to the transport serial, which is the old behaviour.
            states = devices()
            found = [
                Device(serial=serial, state=state)
                for serial, state in states.items()
            ]
        attached_devices = [
            device
            for device in found
            if device.state == "device"
            and (not network_only or ":" in device.serial)
        ]
        if not attached_devices:
            return None
        if len(attached_devices) == 1:
            return attached_devices[0].serial

        groups: dict[str, list[str]] = {}
        for device in attached_devices:
            groups.setdefault(identity(device), []).append(device.serial)
        if len(groups) == 1:
            return _choose_transport(next(iter(groups.values())), values)

        listed = ", ".join(
            f"{serial} ({state})" for serial, state in states.items()
        )
        raise SerialError(
            "more than one adb device is attached: "
            f"{listed}; set PHONE_SERIAL to the one to use"
        )

    serial = choose()
    if serial is None and discover() is not None:
        serial = choose()
    return serial


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
    """The same command aimed at the one serial the operator chose.

    A command that already has `-s` keeps it (and is retargeted when a network
    port went stale). A command without one gets the resolved serial inserted,
    so no adb call can fall back to "the only device adb happened to pick".
    Only a network serial can be stale — a USB one survives a reboot — so the
    cost for the USB case is one string check and no adb call at all.
    """
    argv = list(argv)
    if not argv or argv[0] != "adb":
        return argv
    if subcommand(argv) in SERVER_COMMANDS:
        return argv
    if not subcommand(argv):
        return argv
    found = target(argv)
    if found is None:
        serial = resolve_serial()
        if serial is None:
            return argv
        return [argv[0], "-s", serial, *argv[1:]]
    if not enabled():
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
