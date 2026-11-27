"""Environment, command execution and the small caches checks share."""

from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

# The doctor shares the adb transport fallback with the commands: a phone that
# rebooted keeps its address and changes only its wireless-debugging port.
from phone_link.adb import (
    SerialError,
    prepare,
    resolve_serial,
    retry,
)
from phone_link.config import values as config_values


class Context:
    def __init__(self, env: dict[str, str] | None = None) -> None:
        self.env = dict(os.environ if env is None else env)
        self._config = config_values(self.env)
        self._serial: str | None = None
        self._serial_loaded = False
        self._serial_error = ""
        self._profile: bool | None = None
        self._secrets: dict[str, str] | None = None

    # -- configuration -------------------------------------------------
    def get(self, name: str, default: str) -> str:
        return self.env.get(name) or self._config.get(name) or default

    @property
    def ap_if(self) -> str:
        return self.get("PHONE_AP_IF", "wlp110s0")

    @property
    def ap_con(self) -> str:
        return self.get("PHONE_AP_CON", "phonelink")

    @property
    def ap_ssid(self) -> str:
        return self.get("PHONE_AP_SSID", "PhoneLink")

    @property
    def ap_band(self) -> str:
        return self.get("PHONE_AP_BAND", "a")

    @property
    def ap_channel(self) -> int:
        """The AP channel, from the same env/default as phone-ap-create.

        The module writes PHONE_AP_BAND/PHONE_AP_CHANNEL even at their
        defaults, so the doctor reads the profile's own source rather than the
        generated keyfile; a deployment that never used the module falls back
        to the command's built-in default (5 GHz 149).
        """
        value = self.get("PHONE_AP_CHANNEL", "149")
        return int(value) if value.isdigit() else 149

    @property
    def ap_role(self) -> str:
        """Whether this host owns the AP (`local`) or is only a client of it.

        A typo is treated as `local`: that is the historical behaviour, and the
        external branch deliberately assumes none of the local units exist.
        """
        role = self.get("PHONE_AP_ROLE", "local")
        return role if role in ("local", "external") else "local"

    @property
    def ap_external(self) -> bool:
        return self.ap_role == "external"

    @property
    def ap_declarative(self) -> bool:
        """Whether the module declares the AP (`phoneLink.ap.enable`)."""
        return Path(
            self.get("PHONE_AP_DECLARATIVE", "/etc/phone-link/ap-profile")
        ).is_file()

    @property
    def ap_ip(self) -> str:
        return self.get("PHONE_AP_IP", "192.168.77.232")

    @property
    def hotspot_ip(self) -> str:
        return self.get("PHONE_HOTSPOT_IP", "10.244.108.165")

    @property
    def proxy_pkg(self) -> str:
        return self.get("PHONE_PROXY_PKG", "org.phonelink.proxy")

    @property
    def proxy_port(self) -> str:
        """The port the laptop uses: PHONE_PROXY_PORT, the panel's choice, the module.

        The same order as `phone_link.settings.active_port`, kept here rather
        than imported because a probe may be given its own environment and the
        settings module reads the process's once, at import. Neither an
        explicit value nor the runtime file is trusted unvalidated: a typo in
        the environment must not become a port a probe tries to reach.
        """
        explicit = self.env.get("PHONE_PROXY_PORT")
        if explicit and explicit.isdigit() and 1 <= int(explicit) <= 65535:
            return explicit
        # The module's default comes from /etc/phone-link/env; a bad value is
        # ignored exactly like a bad environment or runtime file.
        configured = self._config.get("PHONE_PROXY_PORT", "1080")
        if not configured.isdigit() or not 1 <= int(configured) <= 65535:
            configured = "1080"
        path = Path(self.get("PHONE_RUNTIME_PORT_FILE", "/run/phone-link/proxy-port"))
        try:
            value = path.read_text().strip()
        except OSError:
            return configured
        if value.isdigit() and 1 <= int(value) <= 65535:
            return value
        return configured

    @property
    def proxy_host(self) -> str:
        """The primary proxy address the module configured."""
        return self.get("PHONE_PROXY_HOST", self.ap_ip)

    @property
    def proxy_user(self) -> str:
        return self.get("PHONE_PROXY_USER", "proxy")

    @property
    def nft(self) -> str | None:
        """The nft binary the AP's no-forward unit runs, or None.

        `PHONE_NFT` comes from the environment or from the module's file and is
        an absolute store path, which a user's PATH does not carry; a shell's
        own `nft` is the last resort for a host without the module. A configured
        path that cannot be run is ignored rather than reported as the answer.
        """
        for candidate in (self.env.get("PHONE_NFT"), self._config.get("PHONE_NFT")):
            if candidate and self.have(candidate):
                return candidate
        return shutil.which("nft", path=self.env.get("PATH"))

    @property
    def secrets_file(self) -> Path:
        return Path(self.get("PHONE_SECRETS", "/etc/nixos/phone-socks-secrets"))

    @property
    def resolv(self) -> Path:
        return Path(self.get("PHONE_DOCTOR_RESOLV", "/etc/resolv.conf"))

    @property
    def probe_url(self) -> str:
        return self.get("PHONE_DOCTOR_URL", "https://example.com")

    @property
    def source_root(self) -> Path:
        # .../lib/python/phone_doctor/context.py -> the checkout or the store
        # share directory that the flake installs next to bin/.
        return Path(__file__).resolve().parents[3]

    # -- commands ------------------------------------------------------
    def _spawn(
        self, argv: list[str], timeout: float | None
    ) -> subprocess.CompletedProcess[str] | None:
        try:
            return subprocess.run(
                argv,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                timeout=timeout,
                env=self.env,
            )
        except (OSError, subprocess.TimeoutExpired):
            return None

    def run(
        self, argv: list[str], timeout: float | None = None
    ) -> subprocess.CompletedProcess[str] | None:
        try:
            argv = prepare(argv)
        except SerialError as exc:
            self._serial_error = str(exc)
            return None
        proc = self._spawn(argv, timeout)
        if proc is None or proc.returncode == 0:
            return proc
        recovered = retry(argv)
        if recovered is None:
            return proc
        return self._spawn(recovered, timeout)

    def text(self, argv: list[str], timeout: float | None = None) -> str:
        """stdout even on a non-zero exit (systemctl is-active does that)."""
        proc = self.run(argv, timeout)
        return proc.stdout if proc is not None else ""

    def have(self, name: str) -> bool:
        """Whether a command or an absolute path can be run.

        The module writes the absolute paths of the tools it uses to
        /etc/phone-link/env, and those are not on a user's PATH; an absolute
        path is therefore checked directly rather than looked up.
        """
        if os.path.isabs(name):
            return os.path.isfile(name) and os.access(name, os.X_OK)
        return shutil.which(name, path=self.env.get("PATH")) is not None

    # -- shared state --------------------------------------------------
    @property
    def serial(self) -> str | None:
        if not self._serial_loaded:
            self._serial_loaded = True
            try:
                self._serial = resolve_serial(self.env)
            except SerialError as exc:
                self._serial_error = str(exc)
        return self._serial

    @property
    def serial_error(self) -> str:
        """Why no serial could be chosen, when it was ambiguous rather than absent."""
        return self._serial_error

    def adb(self, *args: str, timeout: float | None = None) -> str:
        if self.serial is None:
            return ""
        return self.text(["adb", "-s", self.serial, *args], timeout)

    def mdns_adb(self, timeout: float | None = 5) -> tuple[str | None, bool]:
        """Where a phone advertises wireless debugging, and whether it does at all.

        `avahi-browse -rtp _adb-tls-connect._tcp` prints `+;…` when it hears the
        service, and `=;iface;IPv4;name;…;host;address;port;txt` once it has
        resolved an endpoint. That record is the only place the port appears
        before adb knows it — the port is random per start, and adb's own mDNS
        lookup is missing from some builds.

        A name that is announced and never resolves is a phone whose adbd is not
        listening, which is wireless debugging switched off; nothing announced
        at all is a phone that is not on this network. The two faults look the
        same to a reader that only takes the resolved lines, and they are fixed
        differently.
        """
        output = self.text(
            ["avahi-browse", "-rtp", "_adb-tls-connect._tcp"], timeout
        )
        announced = False
        for line in output.splitlines():
            if line.startswith("+"):
                announced = True
                continue
            fields = line.split(";")
            if len(fields) >= 9 and fields[0] == "=" and fields[2] == "IPv4":
                announced = True
                address, port = fields[7], fields[8]
                if address and port.isdigit():
                    return f"{address}:{port}", True
        return None, announced

    def adb_connect(self, address: str) -> str | None:
        """Connect to `address`, forget the cached device, and return it."""
        self.text(["adb", "connect", address], timeout=15)
        self._serial = None
        self._serial_loaded = False
        return self.serial

    def phone_ips(self) -> list[str]:
        ips: list[str] = []
        for line in self.adb("shell", "ip", "-4", "-o", "addr", "show").splitlines():
            fields = line.split()
            if len(fields) >= 4:
                addr = fields[3].split("/")[0]
                if not addr.startswith("127."):
                    ips.append(addr)
        return ips

    def profile_exists(self) -> bool:
        if self._profile is None:
            names = self.text(["nmcli", "-t", "-f", "NAME", "con", "show"])
            self._profile = self.ap_con in names.splitlines()
        return self._profile

    @property
    def target_ip(self) -> str:
        # The phone's address on the AP is the primary host in every topology
        # where the module owns the link.  With an external AP there is no local
        # profile to ask, and the hotspot address would be the wrong phone
        # network; proxyHost is the reservation the setup promises.
        if self.ap_external or self.profile_exists():
            return self.proxy_host
        return self.hotspot_ip

    def secrets(self) -> dict[str, str] | None:
        if self._secrets is None:
            path = self.secrets_file
            try:
                text = path.read_text()
            except OSError:
                return None
            values: dict[str, str] = {}
            for raw in text.splitlines():
                line = raw.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, value = line.partition("=")
                key = key.strip().removeprefix("export ").strip()
                value = value.strip()
                if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                    value = value[1:-1]
                if key:
                    values[key] = value
            self._secrets = values
        return self._secrets

    def proxy_pass(self) -> str | None:
        values = self.secrets()
        if not values:
            return None
        return values.get("PHONE_SOCKS_PASS") or None

    @property
    def proxy_apk(self) -> Path | None:
        """The APK a repair would install: an explicit file, or the cache.

        An explicit file wins even when it is missing — the check says so
        instead of quietly picking another — and the cache is what a repair
        falls back on when this checkout never downloaded a release or the
        network the app provides is the thing that broke.
        """
        override = self.env.get("PHONE_PROXY_APK") or ""
        if override:
            return Path(override)
        return self.apk_cached()

    def apk_cached(self) -> Path | None:
        cache = Path(self.get("PHONE_APK_CACHE", "/var/cache/phone-link"))
        dirs = [
            cache,
            Path(self.env["PHONE_APK_DIR"]) if self.env.get("PHONE_APK_DIR") else None,
            Path(self.get("XDG_CACHE_HOME", str(Path.home() / ".cache")))
            / "phone-link",
        ]
        newest: Path | None = None
        for directory in dirs:
            if directory is None or not directory.is_dir():
                continue
            for apk in directory.glob("*.apk"):
                if not apk.is_file():
                    continue
                if newest is None or apk.stat().st_mtime > newest.stat().st_mtime:
                    newest = apk
        return newest
