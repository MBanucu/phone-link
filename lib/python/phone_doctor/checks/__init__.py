"""Check modules, in report order. Each exposes SECTION and check(ctx)."""

from . import adb_wifi, flake, host, internet, phone, proxy, secrets, tether, tunnel

MODULES = [flake, host, phone, secrets, proxy, tunnel, tether, internet, adb_wifi]

__all__ = ["MODULES"]
