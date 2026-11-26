"""The module's non-secret configuration file.

NixOS writes the ``phoneLink`` options that the commands share to
``/etc/phone-link/env``.  It is a plain ``KEY=VALUE`` file, readable by every
user, and it deliberately holds no secret: the password stays in
``phoneLink.secretsFile`` and is read at run time.

The order every consumer uses is the environment, then this file, then the
built-in default.  That keeps a one-off ``PHONE_*`` override working exactly as
it did before the module wrote the file, and lets a test point
``PHONE_CONFIG_FILE`` at a temporary copy.
"""

from __future__ import annotations

import os
import shlex
from typing import Mapping

DEFAULT_FILE = "/etc/phone-link/env"


def path(env: Mapping[str, str] | None = None) -> str:
    """The configuration file to read, with the test override."""
    values = os.environ if env is None else env
    return values.get("PHONE_CONFIG_FILE") or DEFAULT_FILE


def read_env_file(pathname: str) -> dict[str, str]:
    """Parse a shell-style KEY=VALUE file without executing it.

    The values are written by the Nix module with ``lib.escapeShellArg``, so a
    line can be ``PHONE_AP_SSID='A link with spaces'``.  ``shlex`` reads that
    the same way a shell would; a malformed line is skipped rather than making
    the whole file unreadable.
    """
    values: dict[str, str] = {}
    try:
        text = open(pathname, encoding="utf-8").read()
    except OSError:
        return values
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        try:
            fields = shlex.split(line, comments=True, posix=True)
        except ValueError:
            continue
        if not fields:
            continue
        if fields[0] == "export" and len(fields) > 1:
            fields = fields[1:]
        assignment = " ".join(fields)
        key, separator, value = assignment.partition("=")
        key = key.strip()
        if not separator or not key:
            continue
        values[key] = value
    return values


def values(env: Mapping[str, str] | None = None) -> dict[str, str]:
    """Every value the module wrote, or an empty mapping when it is absent."""
    return read_env_file(path(env))


def get(
    name: str,
    default: str,
    env: Mapping[str, str] | None = None,
    config: Mapping[str, str] | None = None,
) -> str:
    """One value: environment first, then the module file, then the default."""
    environment = os.environ if env is None else env
    configured = values(environment) if config is None else config
    return environment.get(name) or configured.get(name) or default
