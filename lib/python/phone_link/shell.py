"""The small shell vocabulary the scripts share: log, die, have and capture.

`capture` is the read-only counterpart of `runner.stream`: no output to the
terminal, no exception on a missing binary or a non-zero status, because every
caller reports its own verdict. That is what the bash scripts got from
`2>/dev/null` plus `|| true`.
"""

from __future__ import annotations

import shutil
import subprocess
import sys
from typing import NoReturn, Sequence

# A command that hangs must not hang the caller: the bash originals wrapped
# every slow probe in `timeout`.
DEFAULT_TIMEOUT = 120.0


def log(message: str) -> None:
    """Write one report line to stderr, as lib/phone-net.sh's `log` does."""
    print(message, file=sys.stderr)


def die(message: str) -> NoReturn:
    log(f"error: {message}")
    raise SystemExit(1)


def have(name: str) -> bool:
    return shutil.which(name) is not None


def run_text(
    argv: Sequence[str], *, timeout: float = DEFAULT_TIMEOUT
) -> tuple[int, str]:
    """Run a command and return (exit status, stdout) without trailing \\n."""
    try:
        done = subprocess.run(
            list(argv),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=timeout,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return 127, ""
    return done.returncode, done.stdout.rstrip("\n")


def capture(
    argv: Sequence[str], *, timeout: float = DEFAULT_TIMEOUT
) -> str:
    """Run a command and return its stdout, without its trailing newline.

    A missing binary, a timeout or a non-zero exit yields "" rather than an
    error: the callers treat an empty answer as "did not report", exactly like
    `$(cmd 2>/dev/null || true)`.
    """
    try:
        done = subprocess.run(
            list(argv),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=timeout,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return done.stdout.rstrip("\n")


def run(argv: Sequence[str], *, timeout: float | None = None) -> int:
    """Run a command with the caller's stdout and stderr, returning its status."""
    try:
        return subprocess.run(list(argv), timeout=timeout, check=False).returncode
    except (OSError, subprocess.TimeoutExpired):
        return 127


def must(argv: Sequence[str], *, timeout: float | None = None) -> None:
    """Run a command that has to succeed, as `set -e` enforced in bash."""
    code = run(argv, timeout=timeout)
    if code != 0:
        raise SystemExit(code)


def status(argv: Sequence[str], *, timeout: float = DEFAULT_TIMEOUT) -> int:
    """Run a command and return its exit status, 127 when it cannot start."""
    try:
        done = subprocess.run(
            list(argv),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=timeout,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return 127
    return done.returncode
