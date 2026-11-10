"""Direct internet check: a fresh HTTPS request without the proxy."""

from __future__ import annotations

from ..context import Context
from ..model import Result, fail, ok

SECTION = "[internet]"


def check(ctx: Context) -> list[Result]:
    code = ctx.text(
        [
            "curl",
            "-4",
            "-s",
            "-m",
            "20",
            "-o",
            "/dev/null",
            "-w",
            "%{http_code}",
            ctx.probe_url,
        ],
        timeout=20,
    ).strip()
    if code == "200":
        return [ok("https", "https", f"{ctx.probe_url} -> 200")]
    return [fail("https", "https", f"{ctx.probe_url} -> {code or '000'}")]
