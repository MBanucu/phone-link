"""Environment, command execution and the small caches checks share."""

from __future__ import annotations

import os
import re
import shutil
import subprocess
from pathlib import Path

# The doctor shares the adb transport fallback with the commands: a phone that
# rebooted keeps its address and changes only its wireless-debugging port.
from phone_link.adb import discover, prepare, retry


class Context:
    def __init__(self, env: dict[str, str] | None = None) -> None:
        self.env = dict(os.environ if env is None else env)
        self._serial: str | None = None
        self._serial_loaded = False
        self._profile: bool | None = None
        self._secrets: dict[str, str] | None = None

    # -- configuration -------------------------------------------------
    def get(self, name: str, default: str) -> str:
        return self.env.get(name) or default

    @property
    def ap_if(self) -> str:
        return self.get("PHONE_AP_IF", "wlp110s0")

    @property
    def ap_con(self) -> str:
        return self.get("PHONE_AP_CON", "phonelink")

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
        return self.get("PHONE_PROXY_PORT", "1080")

    @property
    def proxy_user(self) -> str:
        return self.get("PHONE_PROXY_USER", "proxy")

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
        argv = prepare(argv)
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
        return shutil.which(name, path=self.env.get("PATH")) is not None

    # -- shared state --------------------------------------------------
    @property
    def serial(self) -> str | None:
        if not self._serial_loaded:
            self._serial_loaded = True
            self._serial = self._first_device()
            if self._serial is None and discover() is not None:
                self._serial = self._first_device()
        return self._serial

    def _first_device(self) -> str | None:
        for line in self.text(["adb", "devices"]).splitlines():
            fields = line.split()
            if len(fields) >= 2 and fields[1] == "device":
                return fields[0]
        return None

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
        return self.ap_ip if self.profile_exists() else self.hotspot_ip

    def secrets(self) -> dict[str, str] | None:
        if self._secrets is None:
            path = self.secrets_file
            try:
                text = path.read_text()
            except OSError:
                return None
            values: dict[str, str] = {}
            for line in text.splitlines():
                match = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$", line)
                if match:
                    values[match.group(1)] = match.group(2)
            self._secrets = values
        return self._secrets

    def proxy_pass(self) -> str | None:
        values = self.secrets()
        if not values:
            return None
        return values.get("PHONE_SOCKS_PASS") or None

    @property
    def proxy_manifest(self) -> Path:
        """The manifest this checkout builds: where the app's version lives."""
        return Path(
            self.get(
                "PHONE_PROXY_MANIFEST",
                str(self.source_root / "android" / "AndroidManifest.xml"),
            )
        )

    @property
    def proxy_apk(self) -> Path | None:
        """The APK a reinstall would use, and the one the version is read from.

        An explicit file wins, then this checkout's build, then whatever is
        cached: the cache is what a repair falls back on when the tree is gone
        or the network the app provides is the thing that broke.
        """
        override = self.env.get("PHONE_PROXY_APK") or ""
        if override:
            # Named explicitly, so it is what a repair would use even if it is
            # missing: the check says so instead of quietly picking another.
            return Path(override)
        built = self.source_root / "android" / "build" / "phone-link-proxy.apk"
        if built.is_file():
            return built
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
