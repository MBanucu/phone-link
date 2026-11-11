"""Capture the control panel's states as PNGs.

Driven by `bin/phone-link-gui-screenshots`: that script builds the GUI, puts the
wrapper's environment on this process and runs this module against the real
window, so the status page shows whatever the doctor reports on the machine.
Each state is grabbed with ImageMagick's `import` from the X display and trimmed
to the window, which leaves no desktop border behind.
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")

from gi.repository import Adw, GLib  # noqa: E402

from phone_link_gui.app import Window
from phone_link_gui.log_window import RunWindow

APP_ID = "org.phonelink.Screenshots"
# ImageMagick 7 renamed convert to magick; use whichever this host has.
MAGICK = "magick" if shutil.which("magick") else "convert"
# Long enough for the page crossfade and for a search's rows to be laid out.
SETTLE = 1.6
# The doctor can take a while (secrets and proxy probes have their own
# timeouts); give up rather than hang when it never reports.
PROBE_POLL = 0.7
PROBE_TRIES = 150

STEPS: list[tuple[str, object]] = []
state: dict = {}
failed: list[str] = []


def capture(name: str, out: str) -> None:
    raw = os.path.join(out, name + ".raw.png")
    final = os.path.join(out, name + ".png")
    subprocess.run(
        ["import", "-display", os.environ["DISPLAY"], "-window", "root",
         "-silent", raw],
        check=False,
    )
    subprocess.run([MAGICK, raw, "-trim", "+repage", final], check=False)
    if os.path.exists(raw):
        os.unlink(raw)
    if not os.path.exists(final) or os.path.getsize(final) == 0:
        failed.append(name)
        print(f"failed {name}: import wrote nothing", file=sys.stderr)
        return
    # An all-black frame means the window painted nothing the X server could
    # see; that produced convincing but useless captures once already.
    mean = subprocess.run(
        [MAGICK, final, "-format", "%[fx:mean]", "info:"],
        capture_output=True,
        text=True,
        check=False,
    )
    try:
        brightness = float(mean.stdout.strip())
    except ValueError:
        brightness = 0.0
    if brightness <= 0.0:
        failed.append(name)
        print(f"failed {name}: captured a black frame", file=sys.stderr)
        return
    print(f"shot {name}", flush=True)


def walk(index: int = 0) -> bool:
    if index >= len(STEPS):
        state["app"].quit()
        return False
    name, action = STEPS[index]
    action()
    GLib.timeout_add(
        int(SETTLE * 1000),
        lambda: (capture(name, state["out"]), walk(index + 1))[1],
    )
    return False


def build_steps(window: Window) -> None:
    for page_id in [page for page in window.page_names() if page != "doctor"]:
        STEPS.append((f"page-{page_id}", lambda p=page_id: window.show_page(p)))
    STEPS.append(("search-results", lambda: window.search("proxy")))
    STEPS.append(("search-empty", lambda: window.search("")))
    STEPS.append(("search-none", lambda: window.search("zzzznothing")))
    STEPS.append(("search-closed", lambda: window._search_button.set_active(False)))
    STEPS.append(
        ("narrow", lambda: (window.set_default_size(430, 780),
                            window.show_page("doctor")))
    )
    STEPS.append(("wide", lambda: window.set_default_size(1000, 720)))

    def failed_run() -> None:
        state["run"] = RunWindow(
            window,
            "Restart the tunnel",
            ["sh", "-c",
             "echo 'restarting the USB tunnel'; sleep 0.4; "
             "echo 'error: adb: no devices/emulators found'; exit 3"],
        )
        state["run"].present()

    STEPS.append(("run-failed", failed_run))


def activate(application) -> None:
    window = Window(application)
    state["window"] = window
    window.present()
    build_steps(window)

    def wait_for_probe(tries: int = 0) -> bool:
        if window._status._busy and tries < PROBE_TRIES:
            return True
        if window._status._busy:
            print("the status probe never finished", file=sys.stderr)
            application.quit()
            return False
        walk(0)
        return False

    GLib.timeout_add(int(PROBE_POLL * 1000), wait_for_probe)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Capture the phone-link GUI.")
    parser.add_argument("--out", default="screenshots", help="output directory")
    args = parser.parse_args(argv)

    missing = [tool for tool in ("import", MAGICK) if shutil.which(tool) is None]
    if missing:
        print(f"missing {', '.join(missing)} (ImageMagick)", file=sys.stderr)
        return 2
    if not os.environ.get("DISPLAY"):
        print("DISPLAY is unset: run this under bin/phone-link-gui-screenshots",
              file=sys.stderr)
        return 2

    out = os.path.abspath(args.out)
    os.makedirs(out, exist_ok=True)
    state["out"] = out

    app = Adw.Application(application_id=APP_ID)
    state["app"] = app
    app.connect("activate", activate)
    app.run([APP_ID])

    names = [name for name, _step in STEPS]
    print(f"wrote {len(names) - len(failed)} of {len(names)} screenshots to {out}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
