"""Entry point for `python3 -m phone_link.commands <script-name>`."""

from __future__ import annotations

import sys

from . import main

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
