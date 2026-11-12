"""Check modules, in report order. Each exposes SECTION and check(ctx)."""

from . import (
    adb_wifi,
    app,
    flake,
    host,
    internet,
    phone,
    proxy,
    secrets,
    tether,
    tunnel,
)

# The app's own section follows the proxy checks: it is only meaningful once the
# phone and the app are reachable.
MODULES = [flake, host, phone, secrets, proxy, app, tunnel, tether, internet, adb_wifi]

__all__ = ["MODULES"]
