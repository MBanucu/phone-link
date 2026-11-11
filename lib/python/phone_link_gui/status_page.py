"""The status page: phone-doctor's findings, rendered from its JSON report."""

from __future__ import annotations

import json
import os
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

# phone-doctor-fix already maps one script per problem (its describe_fix), so
# the rows point at the same registry actions instead of reimplementing a
# repair. Problems missing here are the manual ones and get no button.
def _root_lock() -> Gtk.Image:
    """The lock the action rows show for a run that asks for a password."""
    lock = Gtk.Image.new_from_icon_name("system-lock-screen-symbolic")
    lock.add_css_class("dim-label")
    lock.set_tooltip_text("Needs root: phone-link asks for your password")
    return lock


PROBLEM_FIXES = {
    "apk_cache": "phone-fix-apk",
    "ip_forward": "phone-fix-forwarding",
    "ap_profile": "phone-ap-create",
    "ap_address": "phone-ap-up",
    "phone_unlocked": "phone-unlock",
    "phone_address": "phone-wifi-connect",
    "phone_default": "phone-fix-mobile-data",
    "proxy_app": "phone-proxy-install",
    "proxy_request": "phone-proxy-setup",
    "phone_tun": "phone-fix-tunnel",
    "tunnel_route": "phone-fix-tunnel",
    "rndis0": "phone-usb-tether-default",
    "network_transport": "phone-adb-wifi",
    "https": "phone-fix-internet",
}


class ProbeError(RuntimeError):
    """The doctor could not be run or did not answer with JSON."""


def probe(*, escalate: bool = False) -> dict:
    """Run `phone-doctor --json`, as the user or through pkexec."""
    exe = registry.doctor_bin()
    if not exe:
        raise ProbeError("phone-doctor not found on PATH")
    argv = [exe, "--json"]
    if escalate and os.geteuid() != 0:
        prefix = registry.escalation_prefix()
        if not prefix:
            raise ProbeError("neither sudo nor pkexec is available")
        argv = [*prefix, *argv]

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
        # Once the user has authenticated, later probes keep going through
        # sudo. A plain re-probe would see the root-only checks failing again
        # and put the Authenticate banner back after every action.
        self._escalated = False
        self._pending_escalation = False
        self._is_root = os.geteuid() == 0

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
    def refresh(self, *, escalate: bool | None = None) -> None:
        if self._busy:
            return
        escalate = self._escalation_for(escalate)
        self._busy = True
        self._pending_escalation = escalate
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

    def _escalation_for(self, escalate: bool | None) -> bool:
        """An explicit request wins; otherwise stay as authenticated."""
        return self._escalated if escalate is None else escalate

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
        escalated = self._pending_escalation
        self._window.set_status_busy(False)
        self._spinner.stop()
        if error:
            # sudo's timestamp is gone or the prompt was declined: drop the
            # stickiness so the banner can offer authentication again.
            if escalated and not self._is_root:
                self._escalated = False
            self._placeholder.set_title("Could not check the setup")
            self._placeholder.set_description(error)
            self._placeholder.set_icon_name("dialog-error-symbolic")
            self._placeholder.set_child(self._retry)
            self._view.set_visible_child_name("placeholder")
            self._window.report_error("Status probe failed", error)
            return False
        self._escalated = escalated
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
        button = self._fix_button(result)
        if button is not None:
            # A repair that escalates carries the same lock as on the action
            # pages, so "this asks for a password" is visible before the click.
            if self._needs_root(result):
                row.add_suffix(_root_lock())
            row.add_suffix(button)
        return row

    def _fix_button(self, result: dict) -> Gtk.Button | None:
        """A button that repairs a failing or warning row, when one exists."""
        if result.get("status") not in ("fail", "warn"):
            return None
        problem = result.get("id", "")
        action = registry.BY_ID.get(PROBLEM_FIXES.get(problem, ""))
        if action is not None:
            button = Gtk.Button(label="Fix", valign=Gtk.Align.CENTER)
            button.set_tooltip_text(
                f"Run {action.title}"
                + (" (asks for your password)" if action.root else "")
            )
            button.connect(
                "clicked", lambda _button, a=action: self._window.start_action(a)
            )
            return button
        if problem in AUTH_PROBLEMS:
            # The repair is reading root-only state, not running a script.
            button = Gtk.Button(label="Authenticate", valign=Gtk.Align.CENTER)
            button.set_tooltip_text("Re-check with root so the secrets can be read")
            button.connect("clicked", lambda _button: self.refresh(escalate=True))
            return button
        return None

    def _needs_root(self, result: dict) -> bool:
        """Whether repairing this row escalates, and so needs the lock."""
        problem = result.get("id", "")
        if problem in AUTH_PROBLEMS:
            return True
        action = registry.BY_ID.get(PROBLEM_FIXES.get(problem, ""))
        return bool(action is not None and action.root)

    def _show_auth_banner(self, data: dict) -> None:
        # Already authenticated: the banner must not come back even if a
        # stale report still lists the root-only checks as failing.
        if self._is_root or self._escalated:
            self._banner.set_revealed(False)
            return
        failing = {
            result.get("id")
            for section in data.get("sections", [])
            for result in section.get("results", [])
            if result.get("status") == "fail"
        }
        self._banner.set_revealed(bool(failing & AUTH_PROBLEMS))
