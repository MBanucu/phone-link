"""Is the installed flake lock behind the ref its input pins?"""

from __future__ import annotations

import json
from pathlib import Path

from ..context import Context
from ..model import Result, ok, skip, warn

SECTION = "[flake]"

TAG = "tag"
BRANCH = "branch"
MISSING = "missing"


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


def _input_original(lock: Path) -> dict:
    try:
        data = json.loads(lock.read_text())
        original = data["nodes"]["phone-link"].get("original") or {}
    except (OSError, ValueError, KeyError, TypeError):
        return {}
    return original if isinstance(original, dict) else {}


def _input_remote(lock: Path) -> str:
    """A clone URL for the phone-link input when the lock names one."""
    original = _input_original(lock)
    if original.get("type") == "github":
        owner = original.get("owner")
        repo = original.get("repo")
        if owner and repo:
            return f"https://github.com/{owner}/{repo}"
        return ""
    url = original.get("url")
    return url if isinstance(url, str) else ""


def _input_ref(lock: Path) -> str:
    """The tag or branch the input tracks, if it names one."""
    ref = _input_original(lock).get("ref")
    return ref if isinstance(ref, str) else ""


def _locked_rev(lock: Path) -> str:
    try:
        data = json.loads(lock.read_text())
        rev = data["nodes"]["phone-link"]["locked"]["rev"]
    except (OSError, ValueError, KeyError, TypeError):
        return ""
    return rev if isinstance(rev, str) else ""


def _pinned_commit(ctx: Context, remote: str, ref: str) -> tuple[str, str]:
    """What `ref` names on `remote`: a tag, a branch, missing, or unreachable.

    A tag wins over a branch of the same name, as in git, and the peeled
    (`^{}`) line is preferred: the lock's rev is a commit, so an annotated
    tag's tag object would never match it. `HEAD` is always asked as well, so
    an empty answer means the remote is unreachable rather than the ref gone.
    """
    patterns = ["HEAD"]
    if ref:
        patterns += [
            f"refs/tags/{ref}",
            f"refs/tags/{ref}^{{}}",
            f"refs/heads/{ref}",
        ]
    refs: dict[str, str] = {}
    for line in ctx.text(
        ["git", "ls-remote", remote, *patterns], timeout=10
    ).splitlines():
        fields = line.split()
        if len(fields) >= 2:
            refs[fields[1]] = fields[0]
    if not refs:
        return "", ""
    if ref:
        # An annotated tag prints the tag object first and its commit as
        # refs/tags/<ref>^{}; a lightweight tag prints only the commit.
        peeled = refs.get(f"refs/tags/{ref}^{{}}")
        tag = refs.get(f"refs/tags/{ref}")
        if peeled or tag:
            return TAG, peeled or tag
        branch = refs.get(f"refs/heads/{ref}")
        if branch:
            return BRANCH, branch
        return MISSING, ""
    head = refs.get("HEAD")
    return (BRANCH, head) if head else ("", "")


def _local_head(ctx: Context, src: str) -> str:
    return ctx.text(["git", "-C", src, "rev-parse", "HEAD"]).strip()


def _is_ancestor(ctx: Context, src: str, ancestor: str, descendant: str) -> bool:
    """Whether the checkout already contains `ancestor` (so it is not behind)."""
    proc = ctx.run(
        ["git", "-C", src, "merge-base", "--is-ancestor", ancestor, descendant]
    )
    return proc is not None and proc.returncode == 0


def _check_pin(
    ctx: Context, remote: str, ref: str, locked_rev: str, src: str
) -> list[Result]:
    """Compare the lock with the tag or branch the input actually tracks.

    A tag is expected to be immutable; a branch is expected to move. Only the
    latter makes a newer local checkout relevant, and neither makes a newer
    checkout a reason to warn while the lock still matches its own ref.
    """
    kind, target = _pinned_commit(ctx, remote, ref)
    if not kind:
        return [
            skip(
                "flake_update",
                "flake update",
                "origin unreachable; upstream not checked",
            )
        ]
    if kind == MISSING:
        return [
            warn(
                "flake_update",
                "flake update",
                f"the lock pins {ref}, which origin does not have (re-pin the input)",
            )
        ]
    if target == locked_rev:
        if kind == BRANCH and src:
            head = _local_head(ctx, src)
            if head and head != target and not _is_ancestor(ctx, src, target, head):
                return [
                    warn(
                        "flake_update",
                        "flake update",
                        "origin has newer commits (git pull, then rebuild)",
                    )
                ]
        return [ok("flake_update", "flake update", f"up to date ({target[:12]})")]
    if kind == TAG:
        return [
            warn(
                "flake_update",
                "flake update",
                f"the lock has {locked_rev[:12]}, tag {ref} is at {target[:12]} "
                "(a tag should not move; re-pin the input)",
            )
        ]
    if src:
        head = _local_head(ctx, src)
        if head and head == locked_rev:
            return [
                warn(
                    "flake_update",
                    "flake update",
                    "origin has newer commits (git pull, then rebuild)",
                )
            ]
        if head == target:
            return [
                warn(
                    "flake_update",
                    "flake update",
                    f"system lock is older than {src} HEAD "
                    "(nix flake update phone-link && nixos-rebuild switch)",
                )
            ]
    return [
        warn(
            "flake_update",
            "flake update",
            f"origin is at {target[:12]}, the lock has {locked_rev[:12]} "
            "(nix flake update phone-link && nixos-rebuild switch)",
        )
    ]


def _check_local(ctx: Context, lock: Path, src: str) -> list[Result]:
    """A path input has no remote ref: compare it with the checkout it names."""
    head = _local_head(ctx, src)
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


def _check_remote(ctx: Context, lock: Path) -> list[Result]:
    """Without a checkout, compare the locked revision with the input's remote.

    A GitHub input (what the README pins) leaves no local `.git` behind, and
    the doctor runs from the store, so there is nothing on disk to diff; the
    lock is still comparable with the remote it came from.
    """
    return _check_input(ctx, lock, "")


def _check_input(ctx: Context, lock: Path, src: str) -> list[Result]:
    remote = _input_remote(lock)
    locked_rev = _locked_rev(lock)
    if remote and locked_rev:
        return _check_pin(ctx, remote, _input_ref(lock), locked_rev, src)
    if src:
        return _check_local(ctx, lock, src)
    return [skip("flake_update", "flake update", "no source checkout to compare")]


def check(ctx: Context) -> list[Result]:
    nixos = Path(ctx.get("PHONE_NIXOS_DIR", "/etc/nixos"))
    lock = nixos / "flake.lock"
    src = ctx.get("PHONE_FLAKE_SRC", "")
    if not src:
        src = _source_from_lock(lock)
    if not src and (ctx.source_root / ".git").is_dir():
        src = str(ctx.source_root)

    if not src or not (Path(src) / ".git").is_dir() or not ctx.have("git"):
        return _check_remote(ctx, lock)
    return _check_input(ctx, lock, src)
