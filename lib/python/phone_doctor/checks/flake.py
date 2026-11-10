"""Is the installed flake lock older than the source, or origin ahead?"""

from __future__ import annotations

import json
from pathlib import Path

from ..context import Context
from ..model import Result, ok, skip, warn

SECTION = "[flake]"


def _locked_timestamp(lock: Path) -> int | None:
    try:
        data = json.loads(lock.read_text())
        value = data["nodes"]["phone-link"]["locked"]["lastModified"]
        return int(value)
    except (OSError, ValueError, KeyError, TypeError):
        return None


def _source_from_lock(lock: Path) -> str:
    try:
        data = json.loads(lock.read_text())
        for node in data.get("nodes", {}).values():
            locked = node.get("locked") or {}
            path = locked.get("path")
            if isinstance(path, str):
                return path
    except (OSError, ValueError):
        pass
    return ""


def check(ctx: Context) -> list[Result]:
    nixos = Path(ctx.get("PHONE_NIXOS_DIR", "/etc/nixos"))
    lock = nixos / "flake.lock"
    src = ctx.get("PHONE_FLAKE_SRC", "")
    if not src:
        src = _source_from_lock(lock)
    if not src and (ctx.source_root / ".git").is_dir():
        src = str(ctx.source_root)

    if not src or not (Path(src) / ".git").is_dir() or not ctx.have("git"):
        return [skip("flake_update", "flake update", "no source checkout to compare")]

    head = ctx.text(["git", "-C", src, "rev-parse", "HEAD"]).strip()
    if not head:
        return [skip("flake_update", "flake update", f"{src} is not a git checkout")]

    head_time = ctx.text(["git", "-C", src, "log", "-1", "--format=%ct"]).strip()
    upstream = ""
    for line in ctx.text(
        ["git", "-C", src, "ls-remote", "origin", "HEAD"], timeout=10
    ).splitlines():
        fields = line.split()
        if fields:
            upstream = fields[0]
            break

    locked = _locked_timestamp(lock)
    if locked is not None and head_time.isdigit() and locked < int(head_time):
        return [
            warn(
                "flake_update",
                "flake update",
                f"system lock is older than {src} HEAD "
                "(nix flake update phone-link && nixos-rebuild switch)",
            )
        ]
    if upstream and upstream != head:
        return [
            warn(
                "flake_update",
                "flake update",
                "origin has newer commits (git pull, then rebuild)",
            )
        ]
    if upstream:
        return [ok("flake_update", "flake update", f"up to date ({head[:12]})")]
    return [
        skip(
            "flake_update",
            "flake update",
            "origin unreachable; upstream not checked",
        )
    ]
