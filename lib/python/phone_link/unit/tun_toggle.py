"""Choose the host `phone-tun` dials, once every five-second tick.

`phone-tun-toggle.service` runs this. The declared hosts are probed in order
(the configured primary first, then the fallbacks) and the winner is written to
the host file that `phone-tun-config` and the relay read. The tunnel itself
only learns a new address when its config is regenerated in `ExecStartPre`:
`systemctl start` on a running unit is a no-op, so a changed host needs a
restart.

Android picks a new USB tether subnet on every boot, so a declared USB
fallback goes stale. After every declared host has failed, one tick gathers
gateways: the next hop of each default route and the peer address of a
point-to-point link (`rndis`/tether shows `peer x.x.x.x/32`). Those are
deduplicated against the declared list and the AP host, then probed on the
proxy port exactly like a declared host. The AP is a link, not an uplink, so
it is never probed through the tunnel.

A changed host is confirmed on the next tick before the tunnel is restarted.
That keeps one failed probe (a half-open socket, one dropped packet) from
costing a reconnect and keeps a flapping probe from restarting the tunnel in a
loop; a real failover lands within two ticks (~10 s). The host file is written
immediately, because the relay and the next start read it, but the restart
that re-points the running sing-box waits for the confirmation.

The parsers, the candidate order and the confirmation rule are plain functions
of strings and lists so a test can cover them without a socket, a stub or a
systemd. `main` is the thin edge that reads the environment, probes and calls
systemd.

Values come from the environment, exactly as the shell helper read them:
  PHONE_TUN_HOSTS          hosts in preference order, space separated
  PHONE_TUN_AP_HOST        the AP host, never a gateway candidate (optional)
  PHONE_TUN_GATEWAYS       explicit gateway candidates, space separated;
                           set (even empty) replaces the route/address probe
  PHONE_TUN_IP             ip binary used to find gateways (default ip)
  PHONE_TUN_PORT_FILE      runtime port file (default /run/phone-link/proxy-port)
  PHONE_TUN_FALLBACK_PORT  port when the file is missing or invalid (default 1080)
  PHONE_TUN_HOST_FILE      selected host (default /run/phone-link/proxy-host)
  PHONE_TUN_PENDING_FILE   unconfirmed host (default <host file>.pending)
  PHONE_TUN_CONFIG_FILE    generated sing-box config (default /run/phone-tun/config.json)
  PHONE_TUN_RUNTIME_DIR    directory for the atomic host-file write (default /run/phone-link)
  PHONE_TUN_SYSTEMCTL      systemctl binary (default systemctl)
  PHONE_TUN_UNIT           the unit to start, restart or stop (default phone-tun.service)
  PHONE_TUN_PROBE_TIMEOUT  seconds per TCP probe (default 3)
  PHONE_TUN_PROBE          optional probe command; called with host and port,
                           exit 0 means reachable. Tests use this instead of
                           a real socket.
"""

from __future__ import annotations

import json
import os
import socket
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from typing import Callable, Iterable, Literal, Sequence

PLAN = Literal["settled", "restart", "wait"]


def split_hosts(value: str) -> list[str]:
    """Split a space-separated host list the way the shell helper word-split it."""
    return value.split()


def parse_port(text: str, fallback: int) -> int:
    """The port in `text`, or `fallback` when it is unusable.

    `text` is the port file's contents, so its trailing newlines are ignored.
    Any other character, an empty file, a length over five characters or a
    value outside 1-65535 falls back, as the shell's `[!0-9]` and range tests
    did.
    """
    text = text.rstrip("\n")
    if len(text) > 5 or any(char not in "0123456789" for char in text):
        return fallback
    port = int(text) if text else 0
    if not 1 <= port <= 65535:
        return fallback
    return port


def default_gateways(routes: str) -> list[str]:
    """The `via` next hops in `ip route show default`, in output order."""
    found: list[str] = []
    for line in routes.splitlines():
        fields = line.split()
        for index, field in enumerate(fields[:-1]):
            if field == "via":
                found.append(fields[index + 1])
    return found


def point_to_point_peers(addresses: str) -> list[str]:
    """The `peer` addresses in `ip -4 addr show`, with the prefix length removed."""
    found: list[str] = []
    for line in addresses.splitlines():
        fields = line.split()
        for index, field in enumerate(fields[:-1]):
            if field == "peer":
                found.append(fields[index + 1].partition("/")[0])
    return found


def unique_candidates(candidates: Iterable[str], excluded: Iterable[str]) -> list[str]:
    """Candidates in order, without blanks, repeats or anything excluded.

    The declared hosts and the AP host arrive in `excluded`, so a gateway that
    repeats one of them is never probed twice and the AP is never tried as an
    uplink.
    """
    seen = {item for item in excluded if item}
    chosen: list[str] = []
    for candidate in candidates:
        if not candidate or candidate in seen:
            continue
        seen.add(candidate)
        chosen.append(candidate)
    return chosen


def discovered_candidates(
    routes: str, addresses: str, excluded: Iterable[str]
) -> list[str]:
    """The gateways and peers to try after the declared hosts, deduplicated."""
    return unique_candidates(
        [*default_gateways(routes), *point_to_point_peers(addresses)], excluded
    )


def first_reachable(candidates: Iterable[str], probe: Callable[[str], bool]) -> str:
    """The first candidate `probe` accepts, or "" when none does.

    Probes are lazy and ordered: a declared host that answers means the
    gateways are never even tried.
    """
    for candidate in candidates:
        if probe(candidate):
            return candidate
    return ""


def decision(selected: str, current: str, pending: str) -> PLAN:
    """What to do about a reachable `selected` host.

    `current` is the host the running tunnel actually dials (its generated
    config, not the host file) and `pending` the unconfirmed previous choice.
    A host already dialled is settled; a host that matches last tick's pending
    choice is confirmed and needs the restart; anything else waits one tick so
    a single failed probe does not cost a reconnect.
    """
    if selected == current:
        return "settled"
    if pending == selected:
        return "restart"
    return "wait"


def config_host(text: str) -> str:
    """The `phone` outbound's server in a generated config, or "" when absent.

    A malformed or partial config is "no running host", as the shell helper's
    swallowed Python error was.
    """
    try:
        config = json.loads(text)
    except ValueError:
        return ""
    if not isinstance(config, dict):
        return ""
    outbounds = config.get("outbounds")
    if not isinstance(outbounds, list):
        return ""
    for outbound in outbounds:
        if isinstance(outbound, dict) and outbound.get("tag") == "phone":
            server = outbound.get("server")
            return server if isinstance(server, str) else ""
    return ""


def _read(path: str) -> str:
    """A file's contents without trailing newlines, or "" when it is unreadable."""
    try:
        with open(path, encoding="utf-8") as handle:
            return handle.read().rstrip("\n")
    except OSError:
        return ""


def _write(path: str, directory: str, text: str) -> None:
    """Write one line atomically inside `directory`, as `printf` and `mv` did."""
    descriptor, temporary = tempfile.mkstemp(prefix=".proxy-host.", dir=directory)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(f"{text}\n")
        # The shell's `>>` created 0644 under the unit's umask, next to the
        # 0644 port file, and this file is not secret. mkstemp's 0600 would be
        # a different contract for anything that reads the directory.
        os.chmod(temporary, 0o644)
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise


def _discard(path: str) -> None:
    """`rm -f`: a missing file is not an error and the tick goes on."""
    try:
        os.unlink(path)
    except OSError:
        pass


def _probe_socket(host: str, port: int, timeout: float) -> bool:
    """One TCP connection attempt bounded by the per-probe timeout."""
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def _probe_command(command: str, host: str, port: int) -> bool:
    """Run a test probe binary; exit 0 means the host answered."""
    try:
        done = subprocess.run([command, host, str(port)], check=False)
    except OSError:
        return False
    return done.returncode == 0


def _ip_output(command: str, *arguments: str) -> str:
    """One `ip` invocation's stdout, or "" when it cannot run or fails."""
    try:
        done = subprocess.run(
            [command, *arguments],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            check=False,
        )
    except OSError:
        return ""
    return done.stdout


@dataclass(frozen=True)
class Settings:
    """The environment contract, resolved once per tick."""

    hosts: str
    ap_host: str
    gateways: str | None
    ip: str
    port_file: str
    fallback_port: int
    host_file: str
    pending_file: str
    config_file: str
    runtime_dir: str
    systemctl: str
    unit: str
    probe_timeout: float
    probe_command: str

    @classmethod
    def from_env(cls) -> Settings:
        """Read the helper's variables, applying the same defaults."""
        hosts = os.environ.get("PHONE_TUN_HOSTS", "")
        if not hosts:
            raise SystemExit("PHONE_TUN_HOSTS must list the proxy hosts")
        host_file = (
            os.environ.get("PHONE_TUN_HOST_FILE") or "/run/phone-link/proxy-host"
        )
        return cls(
            hosts=hosts,
            ap_host=os.environ.get("PHONE_TUN_AP_HOST", ""),
            # Presence, not truth: an empty override still turns discovery off.
            gateways=os.environ["PHONE_TUN_GATEWAYS"]
            if "PHONE_TUN_GATEWAYS" in os.environ
            else None,
            ip=os.environ.get("PHONE_TUN_IP") or "ip",
            port_file=os.environ.get("PHONE_TUN_PORT_FILE")
            or "/run/phone-link/proxy-port",
            fallback_port=int(os.environ.get("PHONE_TUN_FALLBACK_PORT") or "1080"),
            host_file=host_file,
            pending_file=os.environ.get("PHONE_TUN_PENDING_FILE")
            or f"{host_file}.pending",
            config_file=os.environ.get("PHONE_TUN_CONFIG_FILE")
            or "/run/phone-tun/config.json",
            runtime_dir=os.environ.get("PHONE_TUN_RUNTIME_DIR") or "/run/phone-link",
            systemctl=os.environ.get("PHONE_TUN_SYSTEMCTL") or "systemctl",
            unit=os.environ.get("PHONE_TUN_UNIT") or "phone-tun.service",
            probe_timeout=float(os.environ.get("PHONE_TUN_PROBE_TIMEOUT") or "3"),
            probe_command=os.environ.get("PHONE_TUN_PROBE", ""),
        )


def _systemctl(settings: Settings, *arguments: str) -> int:
    """Run systemctl with the configured unit last, returning its status."""
    try:
        done = subprocess.run(
            [settings.systemctl, *arguments, settings.unit], check=False
        )
    except OSError:
        return 127
    return done.returncode


def _gateway_candidates(settings: Settings, hosts: Sequence[str]) -> list[str]:
    """The candidates after the declared hosts: the override, or `ip` output."""
    excluded = [settings.ap_host, *hosts]
    if settings.gateways is not None:
        return unique_candidates(split_hosts(settings.gateways), excluded)
    return discovered_candidates(
        _ip_output(settings.ip, "route", "show", "default"),
        _ip_output(settings.ip, "-4", "addr", "show"),
        excluded,
    )


def main() -> int:
    """Run one tick: probe, record the choice, then start, restart or stop."""
    settings = Settings.from_env()
    port = parse_port(_read(settings.port_file), settings.fallback_port)

    def reachable(host: str) -> bool:
        if settings.probe_command:
            return _probe_command(settings.probe_command, host, port)
        return _probe_socket(host, port, settings.probe_timeout)

    hosts = split_hosts(settings.hosts)
    selected = first_reachable(hosts, reachable)
    if not selected:
        selected = first_reachable(_gateway_candidates(settings, hosts), reachable)

    # No host answers: stop the tunnel so traffic cannot stay blackholed, and
    # forget an unconfirmed change so it does not trigger a restart next time.
    if not selected:
        _discard(settings.pending_file)
        return _systemctl(settings, "stop")

    _write(settings.host_file, settings.runtime_dir, selected)

    if _systemctl(settings, "is-active", "--quiet") != 0:
        _discard(settings.pending_file)
        return _systemctl(settings, "start")

    current = config_host(_read(settings.config_file))
    plan = decision(selected, current, _read(settings.pending_file))
    if plan == "settled":
        _discard(settings.pending_file)
        return 0
    if plan == "restart":
        _discard(settings.pending_file)
        return _systemctl(settings, "restart")
    _write(settings.pending_file, settings.runtime_dir, selected)
    return 0


if __name__ == "__main__":
    sys.exit(main())
