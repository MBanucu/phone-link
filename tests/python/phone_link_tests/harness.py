"""One place that builds the stub environment and reports a readable failure.

A suite creates a :class:`Sandbox` (a temporary directory with ``bin/`` and
``log/``), installs the stubs it needs from :mod:`phone_link_tests.stubs`,
writes fixtures with :meth:`Sandbox.write_log` and runs the command with
:meth:`Sandbox.run`.  The stubs are the same idea as ``tests/lib/harness.sh``:
each one appends its argv to ``log/<name>.log`` and then executes
``bin/.<name>.answer`` when a suite wrote one, so the assertion the suite makes
is about what the command printed, not about how the fixture was spelled.

The assertions live in :class:`Case`; a failing one prints the command, the
exit status, what was expected and the whole output, which is what a
``grep -q`` in the shell suite could not do.  Every assertion increments
``checks``, so a case can state how many the shell original had and a tearDown
can prove none was dropped.
"""

from __future__ import annotations

import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
from dataclasses import dataclass
from pathlib import Path
from typing import ClassVar

# tests/python/phone_link_tests/harness.py -> the checkout (or the store copy).
ROOT = Path(__file__).resolve().parents[3]
DOCTOR = ROOT / "bin" / "phone-doctor"

BASH = os.environ.get("BASH") or shutil.which("bash") or "/bin/bash"


@dataclass(frozen=True)
class Run:
    """One finished command: its argv, streams and exit status."""

    argv: tuple[str, ...]
    code: int
    stdout: str
    stderr: str

    @property
    def output(self) -> str:
        """What the shell suite saw with ``>out 2>&1``.

        The doctor prints its report to stdout and only the not-ready verdict to
        stderr, after every stdout line, so concatenating the two is the same
        text the shell captured.
        """
        return self.stdout + self.stderr


class Sandbox:
    """A temporary directory with stubs on PATH, a call log and one env."""

    def __init__(self) -> None:
        self.root = Path(tempfile.mkdtemp(prefix="phone-doctor-python-"))
        self.bin = self.root / "bin"
        self.log = self.root / "log"
        self.cache = self.root / "cache"
        for directory in (self.bin, self.log, self.cache):
            directory.mkdir()

        # A host PHONE_* variable would be a second, invisible fixture; a suite
        # sets every one the doctor reads, so drop whatever the caller had.
        env = {
            key: value
            for key, value in os.environ.items()
            if not key.startswith("PHONE_")
        }
        env.update(
            {
                "PATH": f"{self.bin}:{env.get('PATH', '/usr/bin:/bin')}",
                "HOME": str(self.root),
                "TMP": str(self.root),
                "LOG": str(self.log),
                "STUBS": str(self.bin),
                "XDG_CACHE_HOME": str(self.cache),
                "PHONE_SECRETS": str(self.root / "secrets"),
                "PHONE_DOCTOR_RESOLV": str(self.log / "resolv.conf"),
                "PHONE_AP_DECLARATIVE": str(self.log / "ap-profile"),
                "PHONE_APK_CACHE": str(self.cache),
                "PHONE_PROXY_APK": str(self.root / "app.apk"),
                "PHONE_RUNTIME_PORT_FILE": str(self.root / "runtime-port"),
                "PHONE_CONFIG_FILE": str(self.root / "phone-link-env"),
                "PHONE_NIXOS_DIR": str(self.root / "nixos"),
                "PHONE_FLAKE_SRC": str(self.root / "no-src"),
            }
        )
        self.env = env

    # -- fixtures ------------------------------------------------------
    def write_log(self, name: str, text: str) -> None:
        (self.log / name).write_text(text, encoding="utf-8")

    def append_log(self, name: str, text: str) -> None:
        with (self.log / name).open("a", encoding="utf-8") as handle:
            handle.write(text)

    def read_log(self, name: str) -> str:
        try:
            return (self.log / name).read_text(encoding="utf-8")
        except OSError:
            return ""

    def remove_log(self, name: str) -> None:
        try:
            (self.log / name).unlink()
        except OSError:
            pass

    def touch_log(self, name: str) -> None:
        self.write_log(name, "")

    def secrets(self, text: str, mode: int = 0o600) -> None:
        path = Path(self.env["PHONE_SECRETS"])
        path.write_text(text, encoding="utf-8")
        path.chmod(mode)

    # -- stubs ---------------------------------------------------------
    def stub(self, name: str) -> None:
        """Write the logging stub for NAME (``adb`` included)."""
        script = (
            f"#!{BASH}\n"
            f"log=$LOG/{name}.log\n"
            'mkdir -p "${log%/*}" 2>/dev/null || true\n'
            'printf "%s\\n" "$*" >>"$log"\n'
            f"answer=$STUBS/.{name}.answer\n"
            'if [ -x "$answer" ]; then exec "$answer" "$@"; fi\n'
            "exit 0\n"
        )
        self.write_script(self.bin / name, script)

    def answer(self, name: str, body: str) -> None:
        """Write ``bin/.NAME.answer``; it runs with the stub's argv."""
        body = body.rstrip("\n") + "\n"
        self.write_script(self.bin / f".{name}.answer", f"#!{BASH}\n{body}")

    def write_script(self, path: Path, text: str) -> None:
        path.write_text(text, encoding="utf-8")
        path.chmod(0o755)

    # -- commands ------------------------------------------------------
    def run(self, *args: str, env: dict[str, str] | None = None) -> Run:
        """Run ``bin/phone-doctor ARGS`` with the sandbox environment."""
        return self.execute([BASH, str(DOCTOR), *args], env=env)

    def run_python(
        self,
        code: str,
        *args: str,
        env: dict[str, str] | None = None,
    ) -> Run:
        """Run CODE with this interpreter, as the shell suite's here-doc did."""
        return self.execute(
            [sys.executable or "python3", "-", *args],
            env=env,
            stdin=code,
        )

    def execute(
        self,
        argv: list[str],
        *,
        env: dict[str, str] | None = None,
        stdin: str | None = None,
        timeout: float = 120,
    ) -> Run:
        merged = dict(self.env)
        if env:
            merged.update(env)
        proc = subprocess.run(
            argv,
            cwd=self.root,
            env=merged,
            input=stdin,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        return Run(tuple(argv), proc.returncode, proc.stdout, proc.stderr)

    def close(self) -> None:
        shutil.rmtree(self.root, ignore_errors=True)

    # -- paths a case moves around ------------------------------------
    @property
    def stub_path(self) -> Path:
        return self.bin


class Case(unittest.TestCase):
    """A case that counts its assertions and explains a failure."""

    maxDiff = None
    ASSERTIONS: ClassVar[dict[str, int]] = {}

    def setUp(self) -> None:
        self.sandbox = Sandbox()
        self.addCleanup(self.sandbox.close)
        self.checks = 0

    def tearDown(self) -> None:
        expected = self.ASSERTIONS.get(self._testMethodName)
        if expected is not None and self.checks != expected:
            self.fail(
                f"{self._testMethodName} ran {self.checks} assertions; "
                f"the shell case has {expected}"
            )

    # -- the assertions ------------------------------------------------
    def assert_exit(self, run: Run, code: int, description: str) -> None:
        self.checks += 1
        if run.code != code:
            self.fail(
                self._failure(
                    run,
                    description,
                    f"exit status {code}",
                    f"exit status {run.code}",
                )
            )

    def assert_contains(self, run: Run, text: str, description: str) -> None:
        self.checks += 1
        if text not in run.output:
            self.fail(
                self._failure(
                    run,
                    description,
                    f"output containing {text!r}",
                    "no such text",
                )
            )

    def assert_matches(self, run: Run, pattern: str, description: str) -> None:
        self.checks += 1
        if re.search(pattern, run.output, re.MULTILINE) is None:
            self.fail(
                self._failure(
                    run,
                    description,
                    f"a line matching {pattern!r}",
                    "no line matched",
                )
            )

    def assert_absent(self, run: Run, pattern: str, description: str) -> None:
        self.checks += 1
        match = re.search(pattern, run.output, re.MULTILINE)
        if match is not None:
            self.fail(
                self._failure(
                    run,
                    description,
                    f"no line matching {pattern!r}",
                    f"matched {match.group(0)!r}",
                )
            )

    def assert_equal(self, actual: str, expected: str, description: str) -> None:
        self.checks += 1
        if actual != expected:
            self.fail(
                f"{description}\n  expected: {expected!r}\n  actual:   {actual!r}"
            )

    def assert_text_contains(self, actual: str, text: str, description: str) -> None:
        self.checks += 1
        if text not in actual:
            self.fail(
                f"{description}\n"
                f"  expected to contain: {text!r}\n"
                f"  actual:              {actual!r}"
            )

    @staticmethod
    def _failure(run: Run, description: str, expected: str, actual: str) -> str:
        output = run.output.rstrip("\n") or "<no output>"
        return (
            f"{description}\n"
            f"  command:  {shlex.join(run.argv)}\n"
            f"  exit:     {run.code}\n"
            f"  expected: {expected}\n"
            f"  actual:   {actual}\n"
            f"  output:\n{textwrap.indent(output, '    ')}"
        )
