"""Secrets file checks: readable, required keys, AP password."""

from __future__ import annotations

from ..context import Context
from ..model import Result, fail, ok, warn

SECTION = "[secrets]"


def check(ctx: Context) -> list[Result]:
    values = ctx.secrets()
    if values is None:
        return [
            fail(
                "secrets",
                "secrets",
                f"{ctx.secrets_file} not readable (run with sudo)",
            )
        ]

    results: list[Result] = []
    missing = [key for key in ("PHONE_SOCKS_PASS", "PHONE_PIN") if key not in values]
    if missing:
        results.append(fail("secrets", "secrets", f"missing {' '.join(missing)}"))
    else:
        results.append(ok("secrets", "secrets", str(ctx.secrets_file)))

    try:
        mode = ctx.secrets_file.stat().st_mode & 0o777
    except OSError:
        mode = None
    if mode is not None:
        if mode == 0o600:
            results.append(ok("secrets_mode", "secrets mode", "600"))
        else:
            results.append(
                warn(
                    "secrets_mode",
                    "secrets mode",
                    f"{mode:04o} (should be 600)",
                )
            )

    if "PHONE_AP_PASS" in values:
        results.append(ok("ap_pass", "secrets", "PHONE_AP_PASS present"))
    else:
        results.append(
            warn(
                "ap_pass",
                "secrets",
                "PHONE_AP_PASS missing (phone-wifi-connect needs it)",
            )
        )
    return results
