"""The status page: phone-doctor's findings, rendered from its JSON report."""

from __future__ import annotations

import json
import os
import shutil
import threading

from gi.repository import Adw, GLib, Gtk

from phone_link import actions as registry
from phone_link.runner import stream

SECTION_TITLES = {
    "[flake]": "Flake",
    "[host]": "Host",
    "[phone]": "Phone",
    "[secrets]": "Secrets",
    "[proxy]": "Proxy",
    "[tunnel]": "Tunnel",
    "[usb tether]": "USB tether",
    "[internet]": "Internet",
    "[adb over wi-fi]": "adb over Wi-Fi",
}

STATUS_ICONS = {
    "ok": ("object-select-symbolic", "success"),
    "warn": ("dialog-warning-symbolic", "warning"),
    "fail": ("dialog-error-symbolic", "error"),
    "skip": ("action-unavailable-symbolic", "dim-label"),
}

AUTH_PROBLEMS = {"secrets", "ap_pass", "proxy_request"}


class ProbeError(RuntimeError):
    """The doctor could not be run or did not answer with JSON."""


def probe(*, escalate: bool = False) -> dict:
    """Run `phone-doctor --json`, as the user or through pkexec."""
    exe = registry.doctor_bin()
    if not exe:
        raise ProbeError("phone-doctor not found on PATH")
    argv = [exe, "--json"]
    if escalate and os.geteuid() != 0:
        pkexec = shutil.which("pkexec")
        if not pkexec:
            raise ProbeError("pkexec not found; start the app in a desktop session")
        argv = [pkexec, *argv]

    outcome = stream(argv, timeout=180)
    if outcome.error:
        raise ProbeError(outcome.error)
    body = outcome.text().strip()
    if not body:
        raise ProbeError(f"phone-doctor printed nothing (exit {outcome.exit_code})")
    try:
        return json.loads(body)
    except ValueError as exc:
        raise ProbeError(f"phone-doctor did not return JSON: {exc}") from exc


class StatusPage(Gtk.Box):
    def __init__(self, window):
        super().__init__(orientation=Gtk.Orientation.VERTICAL)
        self._window = window
        self._busy = False
        self._groups: list[Adw.PreferencesGroup] = []

        self._banner = Adw.Banner(
            title="Secrets are root-only; some checks need authentication.",
            button_label="Authenticate",
        )
        self._banner.set_revealed(False)
        self._banner.connect("button-clicked", self._on_authenticate)
        self.append(self._banner)

        self._page = Adw.PreferencesPage()
        self._page.set_vexpand(True)

        # A blank page while the first probe runs reads as "broken"; a failed
        # probe used to leave the page empty with only a toast behind it.
        self._placeholder = Adw.StatusPage(
            icon_name="utilities-system-monitor-symbolic",
            title="Checking the setup",
        )
        self._spinner = Gtk.Spinner()
        self._retry = Gtk.Button(label="Try again", halign=Gtk.Align.CENTER)
        self._retry.add_css_class("pill")
        self._retry.connect("clicked", lambda _b: self.refresh())
        self._placeholder.set_child(self._spinner)

        self._view = Gtk.Stack(
            transition_type=Gtk.StackTransitionType.CROSSFADE, vexpand=True
        )
        self._view.add_named(self._placeholder, "placeholder")
        self._view.add_named(self._page, "page")
        self.append(self._view)

    # -- probing -------------------------------------------------------
    def refresh(self, *, escalate: bool = False) -> None:
        if self._busy:
            return
        self._busy = True
        self._banner.set_revealed(False)
        self._show_progress()
        self._window.set_status_busy(True)
        threading.Thread(target=self._probe, args=(escalate,), daemon=True).start()

    def _show_progress(self) -> None:
        self._placeholder.set_title("Checking the setup")
        self._placeholder.set_description(
            "phone-doctor is looking at the flake, the host and the phone."
        )
        self._placeholder.set_icon_name("utilities-system-monitor-symbolic")
        if self._placeholder.get_child() is not self._spinner:
            self._placeholder.set_child(self._spinner)
        self._spinner.start()
        self._view.set_visible_child_name("placeholder")

    def refresh_if_idle(self) -> None:
        if not self._busy:
            self.refresh()

    def _probe(self, escalate: bool) -> None:
        data = None
        error = ""
        try:
            data = probe(escalate=escalate)
        except Exception as exc:  # the page reports any failure as a toast
            error = str(exc)
        GLib.idle_add(self._apply, data, error)

    def _apply(self, data, error) -> bool:
        self._busy = False
        self._window.set_status_busy(False)
        self._spinner.stop()
        if error:
            self._placeholder.set_title("Could not check the setup")
            self._placeholder.set_description(error)
            self._placeholder.set_icon_name("dialog-error-symbolic")
            self._placeholder.set_child(self._retry)
            self._view.set_visible_child_name("placeholder")
            self._window.report_error("Status probe failed", error)
            return False
        self._render(data)
        self._view.set_visible_child_name("page")
        self._window.report_status(data)
        self._show_auth_banner(data)
        return False

    def _on_authenticate(self, _banner) -> None:
        self.refresh(escalate=True)

    # -- rendering -----------------------------------------------------
    def _render(self, data: dict) -> None:
        for group in self._groups:
            self._page.remove(group)
        self._groups.clear()

        counts = data.get("counts", {})
        ready = bool(data.get("ready"))
        warns = counts.get("warn", 0)
        summary = Adw.PreferencesGroup(title="Verdict")
        row = Adw.ActionRow(
            title="ready" if ready else "not ready",
            subtitle=(
                f"{counts.get('ok', 0)} ok · {counts.get('fail', 0)} failed · "
                f"{warns} warning" + ("" if warns == 1 else "s")
            )
            + f" · {counts.get('skip', 0)} skipped",
        )
        icon = Gtk.Image.new_from_icon_name(
            "object-select-symbolic" if ready else "dialog-error-symbolic"
        )
        icon.add_css_class("success" if ready else "error")
        row.add_prefix(icon)
        button = Gtk.Button(label="Run status", valign=Gtk.Align.CENTER)
        button.connect(
            "clicked",
            lambda _b: self._window.start_action(registry.BY_ID["phone-net-status"]),
        )
        row.add_suffix(button)
        summary.add(row)
        self._page.add(summary)
        self._groups.append(summary)

        for section in data.get("sections", []):
            name = section.get("name", "")
            results = section.get("results", [])
            title = SECTION_TITLES.get(name) or name.strip("[]").title()
            # Say in the heading itself which sections need attention, so a
            # long report can be skimmed without reading every row.
            fails = sum(1 for result in results if result.get("status") == "fail")
            warns = sum(1 for result in results if result.get("status") == "warn")
            if fails:
                title = f"{title} · {fails} failing"
            elif warns:
                title = f"{title} · {warns} warning" + ("" if warns == 1 else "s")
            group = Adw.PreferencesGroup(title=title)
            for result in results:
                group.add(self._row(result))
            self._page.add(group)
            self._groups.append(group)

    def _row(self, result: dict) -> Adw.ActionRow:
        status = result.get("status", "skip")
        icon_name, css = STATUS_ICONS.get(status, STATUS_ICONS["skip"])
        # AdwActionRow renders title and subtitle as Pango markup, and the
        # doctor's details contain "<" ("minSdk 26 <= phone SDK 35"), which
        # would make Pango drop the whole string and log a warning.
        row = Adw.ActionRow(
            title=GLib.markup_escape_text(result.get("label", "")),
            subtitle=GLib.markup_escape_text(result.get("detail", "")),
        )
        row.set_subtitle_selectable(True)
        icon = Gtk.Image.new_from_icon_name(icon_name)
        icon.add_css_class(css)
        row.add_prefix(icon)
        return row

    def _show_auth_banner(self, data: dict) -> None:
        if os.geteuid() == 0:
            self._banner.set_revealed(False)
            return
        failing = {
            result.get("id")
            for section in data.get("sections", [])
            for result in section.get("results", [])
            if result.get("status") == "fail"
        }
        self._banner.set_revealed(bool(failing & AUTH_PROBLEMS))
