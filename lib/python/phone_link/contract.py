"""The proxy app's contract version: one integer both sides agree on.

The app owns the adb contract. Since contract 1 it prints the version as its
own line, both in `dumpsys activity service` and as the first line of the
non-secret ``state.txt``::

    contract_version 1

An app that replaces the line with a feature name, or that has no line at
all, is contract 0. The integer's history is short:

- 0 -- every build before the line.
- 1 -- the first app that prints the line.

The laptop parses the integer and nothing else. A command that needs a
contract this laptop knows refuses an older app; a newer app is reported and
used, because the actions this laptop knows are still the actions it sends.
"""

from __future__ import annotations

import re

# The contract this checkout speaks. Bump it only with a change that the
# laptop cannot make against the previous integer.
KNOWN = 1

TOO_OLD = "too old"
CURRENT = "known"
NEWER = "newer"

# Both sources indent the line differently -- `state.txt` starts it at column
# zero, the service block indents it -- and a dump repeats its help text before
# the live block. The last match is therefore the live answer, exactly as
# `_field` reads the other service lines.
_VERSION = re.compile(r"^[ \t]*contract_version[ \t]+(\d+)[ \t]*$", re.M)


def parse(text: str) -> int | None:
    """The last ``contract_version <n>`` in a dumpsys dump or ``state.txt``.

    ``None`` means the app does not print a version at all, which is contract
    0: an app older than the line.
    """
    matches = _VERSION.findall(text or "")
    return int(matches[-1]) if matches else None


def check(version: int | None) -> str:
    """How this laptop sees one parsed version: too old, known or newer."""
    if version is None or version < KNOWN:
        return TOO_OLD
    if version == KNOWN:
        return CURRENT
    return NEWER
