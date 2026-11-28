"""The port page: which port the laptop uses, and how to choose another.

The page reads `phone-proxy-switch --list` — the app's own `dumpsys` over adb —
and shows the saved proxies by name. A choice runs the same script the CLI
runs, in a log window: the order (the phone first, the laptop only once the new
port answered) is the script's decision, not this page's.
"""

from __future__ import annotations

import json
import threading

from gi.repository import Adw, GLib, Gtk

from phone_link import actions as registry
from phone_link.runner import stream


class ListError(RuntimeError):
    """The switch could not list the phone's proxies."""


def list_ports() -> dict:
    """`phone-proxy-switch --list`, parsed; the script's own words on failure."""
    exe = registry.binary(registry.BY_ID["phone-proxy-switch"])
    outcome = stream([exe, "--list"], timeout=30)
    if outcome.error:
        raise ListError(outcome.error)
    body = outcome.text().strip()
    if outcome.exit_code != 0:
        raise ListError(body or f"exit {outcome.exit_code}")
    try:
        return json.loads(body)
    except ValueError as exc:
        raise ListError(f"the switch did not return JSON: {exc}") from exc


class PortPage(Gtk.Box):
    def __init__(self, window):
        super().__init__(orientation=Gtk.Orientation.VERTICAL)
        self._window = window
        self._busy = False
        self._items: list[dict] = []

        page = Adw.PreferencesPage()
        page.set_vexpand(True)

        self._active_group = Adw.PreferencesGroup(title="In use")
        self._active = Adw.ActionRow(title="Port", subtitle="not read yet")
        self._active.set_subtitle_selectable(True)
        recheck = Gtk.Button(label="Re-check", valign=Gtk.Align.CENTER)
        recheck.connect("clicked", lambda _b: self.refresh())
        self._active.add_suffix(recheck)
        self._active_group.add(self._active)
        page.add(self._active_group)

        self._choose = Adw.PreferencesGroup(
            title="Make another port the active one",
            description=(
                "The phone starts the proxy first; the laptop follows only once "
                "a request through the new port has answered."
            ),
        )
        self._combo = Adw.ComboRow(title="Saved on the phone")
        self._combo.set_subtitle("reading the phone…")
        self._combo.connect("notify::selected", self._on_selected)
        self._use_saved = Gtk.Button(label="Use", valign=Gtk.Align.CENTER)
        self._use_saved.set_sensitive(False)
        self._use_saved.connect("clicked", lambda _b: self._apply_saved())
        self._combo.add_suffix(self._use_saved)
        self._choose.add(self._combo)

        self._entry = Adw.EntryRow(title="Another port")
        self._entry.set_input_purpose(Gtk.InputPurpose.DIGITS)
        self._entry.connect("entry-activated", lambda _row: self._apply_typed())
        self._use_port = Gtk.Button(label="Use", valign=Gtk.Align.CENTER)
        self._use_port.set_tooltip_text("Use a port the phone is already listening on")
        self._use_port.connect("clicked", lambda _b: self._apply_typed())
        self._entry.add_suffix(self._use_port)
        self._choose.add(self._entry)
        page.add(self._choose)

        self.append(page)

    # -- reading -------------------------------------------------------
    def refresh(self) -> None:
        if self._busy:
            return
        self._busy = True
        self._active.set_subtitle("reading the phone…")
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self) -> None:
        data = None
        error = ""
        try:
            data = list_ports()
        except Exception as exc:  # reported in the row, never as a traceback
            error = str(exc)
        GLib.idle_add(self._apply, data, error)

    def _apply(self, data, error) -> bool:
        self._busy = False
        if error:
            self._active.set_title("Port")
            self._active.set_subtitle(f"could not read the phone: {error}")
            self._items = []
            self._combo.set_model(Gtk.StringList.new(["nothing to choose"]))
            self._combo.set_selected(Gtk.INVALID_LIST_POSITION)
            self._combo.set_subtitle("the phone did not answer")
            self._use_saved.set_sensitive(False)
            return False

        active = int(data.get("active", 0))
        running = [int(port) for port in data.get("running", [])]
        saved = data.get("saved", [])
        self._active.set_title(f"Port {active}")
        if not running:
            listing = "nothing"
            verdict = "the phone is not listening"
        else:
            listing = ", ".join(str(port) for port in running)
            verdict = (
                "the laptop and the phone agree"
                if active in running
                else "the phone is listening elsewhere"
            )
        self._active.set_subtitle(f"the phone listens on {listing} — {verdict}")

        self._items = []
        labels: list[str] = []
        saved_ports = set()
        for entry in saved:
            port = int(entry.get("port") or 0)
            if port:
                saved_ports.add(port)
            state = "listening" if entry.get("running") else "not listening"
            label = f"{entry.get('name')} · port {port} · {state}"
            if not entry.get("offerable", True) and entry.get("why"):
                label += f" — {entry['why']}"
            self._items.append(
                {
                    "name": entry.get("name"),
                    "port": port,
                    "offerable": bool(entry.get("offerable", True)),
                    "why": entry.get("why", ""),
                }
            )
            labels.append(label)
        for port in running:
            if port not in saved_ports:
                self._items.append(
                    {"name": "", "port": port, "offerable": True, "why": ""}
                )
                labels.append(f"port {port} · listening")

        self._combo.set_model(
            Gtk.StringList.new(labels or ["nothing saved on the phone"])
        )
        self._combo.set_subtitle("pick one" if labels else "nothing saved or listening")
        self._combo.set_selected(0 if labels else Gtk.INVALID_LIST_POSITION)
        self._on_selected(self._combo, None)
        return False

    # -- choosing ------------------------------------------------------
    def _on_selected(self, _row, _pspec) -> None:
        index = self._combo.get_selected()
        if not 0 <= index < len(self._items):
            self._use_saved.set_sensitive(False)
            self._use_saved.set_tooltip_text("Nothing to use")
            return
        item = self._items[index]
        self._use_saved.set_sensitive(bool(item["offerable"]))
        if item["offerable"]:
            self._use_saved.set_tooltip_text("Make this the active port")
        else:
            self._use_saved.set_tooltip_text(item["why"] or "The laptop cannot use it")

    def _apply_saved(self) -> None:
        index = self._combo.get_selected()
        if not 0 <= index < len(self._items):
            return
        item = self._items[index]
        if not item["offerable"]:
            self._window.report_error("Proxy port", item["why"])
            return
        if item["name"]:
            self._window.run_switch(("--profile", item["name"]))
        else:
            self._window.run_switch(("--port", str(item["port"])))

    def _apply_typed(self) -> None:
        text = self._entry.get_text().strip()
        if not text.isdigit() or not 1 <= int(text) <= 65535:
            self._window.report_error("Proxy port", "the port must be a number")
            return
        self._window.run_switch(("--port", text))
