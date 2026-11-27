"""The GUI's own version, as packaged.

The flake puts the package version in the wrapper's environment. A run from a
checkout has no package metadata, so it says ``development`` instead of
inventing a number; the about dialog can always show something truthful.
"""

from __future__ import annotations

import os

FALLBACK = "development"


def gui_version() -> str:
    """The packaged version, or ``development`` when nothing passed one in."""
    return os.environ.get("PHONE_LINK_VERSION", "").strip() or FALLBACK
