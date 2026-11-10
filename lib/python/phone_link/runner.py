"""Run one action and stream its output: the single execution path.

`phone-link run` prints the lines as they arrive; the GUI does the same into a
log view. Merging stderr into stdout keeps the order the script wrote it, and
stdin is /dev/null so a script that still prompts fails fast instead of
hanging a GUI thread.
"""

from __future__ import annotations

import os
import subprocess
import threading
import time
from dataclasses import dataclass
from typing import Callable, Iterable


@dataclass(frozen=True)
class Outcome:
    argv: tuple[str, ...]
    exit_code: int
    lines: tuple[str, ...]
    duration: float
    cancelled: bool = False
    error: str = ""

    @property
    def ok(self) -> bool:
        return self.exit_code == 0 and not self.error and not self.cancelled

    def text(self) -> str:
        return "\n".join(self.lines)


def stream(
    argv: Iterable[str],
    *,
    on_line: Callable[[str], None] | None = None,
    env: dict[str, str] | None = None,
    timeout: float | None = None,
    cancel: threading.Event | None = None,
    cwd: str | None = None,
) -> Outcome:
    started = time.monotonic()
    argv = tuple(argv)
    lines: list[str] = []
    full_env = dict(os.environ if env is None else env)
    full_env.setdefault("PYTHONDONTWRITEBYTECODE", "1")

    try:
        proc = subprocess.Popen(
            argv,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
            env=full_env,
            cwd=cwd,
        )
    except OSError as exc:
        return Outcome(argv, 127, (), time.monotonic() - started, error=str(exc))

    state = {"cancelled": False}
    deadline = None if timeout is None else started + timeout

    def stop() -> None:
        try:
            proc.terminate()
        except OSError:
            return
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            try:
                proc.kill()
            except OSError:
                pass

    def watchdog() -> None:
        while proc.poll() is None:
            if cancel is not None and cancel.is_set():
                state["cancelled"] = True
                stop()
                return
            if deadline is not None and time.monotonic() > deadline:
                stop()
                return
            time.sleep(0.1)

    watcher = threading.Thread(target=watchdog, daemon=True)
    watcher.start()

    assert proc.stdout is not None
    try:
        for raw in proc.stdout:
            line = raw.rstrip("\n")
            lines.append(line)
            if on_line is not None:
                on_line(line)
    finally:
        exit_code = proc.wait()
        watcher.join(timeout=1)

    return Outcome(
        argv,
        exit_code,
        tuple(lines),
        time.monotonic() - started,
        cancelled=state["cancelled"],
    )
