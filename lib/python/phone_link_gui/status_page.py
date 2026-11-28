"""The status page: phone-doctor's findings, streamed from its JSON report."""

from __future__ import annotations

import os
import threading
from dataclasses import dataclass

from gi.repository import Adw, GLib, Gtk

from phone_doctor.status import section_names

from phone_link import actions as registry
from phone_link import settings
from phone_link.ap_state import ap_is_on
from phone_link.runner import stream

from .status_model import StatusStream, parse_line

AP_ON_SUBTITLE = (
    "On — the phone joins PhoneLink; this radio cannot scan for other networks."
)
AP_OFF_SUBTITLE = (
    "Off — the phone link is down by design; join a network in system settings."
)

SECTION_TITLES = {
    "[flake]": "Flake",
    "[host]": "Host",
    "[phone]": "Phone",
    "[secrets]": "Secrets",
    "[proxy]": "Proxy",
    "[app]": "App",
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


def probe_ap() -> bool:
    """Whether the AP is really on, without root or a NetworkManager-only view."""
    active = stream(
        ["nmcli", "-t", "-f", "NAME,DEVICE", "con", "show", "--active"],
        timeout=5,
    )
    info = stream(["iw", "dev", settings.PHONE_AP_IF, "info"], timeout=5)
    return ap_is_on(
        "" if active.error else active.text(),
        "" if info.error else info.text(),
        settings.PHONE_AP_CON,
    )


def _counts_text(counts: dict) -> str:
    warns = counts.get("warn", 0)
    return (
        f"{counts.get('ok', 0)} ok · {counts.get('fail', 0)} failed · "
        f"{warns} warning" + ("" if warns == 1 else "s")
    ) + f" · {counts.get('skip', 0)} skipped"


def _spinner() -> Gtk.Spinner:
    spinner = Gtk.Spinner()
    spinner.set_size_request(16, 16)
    spinner.set_valign(Gtk.Align.CENTER)
    spinner.start()
    return spinner


@dataclass
class _RowView:
    """The widgets of one check row, kept across a refresh."""

    row: Adw.ActionRow
    section: str
    cid: str
    prefix: Gtk.Widget | None = None
    button: Gtk.Button | None = None
    lock: Gtk.Image | None = None


class StatusPage(Gtk.Box):
    def __init__(self, window):
        super().__init__(orientation=Gtk.Orientation.VERTICAL)
        self._window = window
        self._busy = False
        # Once the user has authenticated, later probes keep going through
        # sudo. A plain re-probe would see the root-only checks failing again
        # and put the Authenticate banner back after every action.
        self._escalated = False
        self._pending_escalation = False
        self._is_root = os.geteuid() == 0
        self._ap_probing = False
        self._ap_acting = False
        self._ap_updating = False
        self._ap_shut = False

        self._sections = list(section_names())
        self._model = StatusStream(self._sections)
        self._has_report = False
        self._rows: dict[tuple[str, str], _RowView] = {}
        self._section_groups: dict[str, Adw.PreferencesGroup] = {}
        self._section_bases: dict[str, str] = {}
        self._placeholders: dict[str, Adw.ActionRow] = {}
        self._summary_group: Adw.PreferencesGroup | None = None
        self._summary_row: Adw.ActionRow | None = None
        self._summary_prefix: Gtk.Widget | None = None

        self._banner = Adw.Banner(
            title="Secrets are root-only; some checks need authentication.",
            button_label="Authenticate",
        )
        self._banner.set_revealed(False)
        self._banner.connect("button-clicked", self._on_authenticate)
        self.append(self._banner)

        self._page = Adw.PreferencesPage()
        self._page.set_vexpand(True)

        # The one control on this page: the doctor explains, this switches. It
        # stays above the findings and is probed without root, so opening the
        # window never asks for a password.
        self._ap_group = Adw.PreferencesGroup(title="Wi-Fi mode")
        self._ap_switch = Adw.SwitchRow(title="PhoneLink access point")
        self._ap_switch.set_subtitle("Checking whether the access point is on…")
        self._ap_switch.set_sensitive(False)
        self._ap_switch.connect("notify::active", self._on_ap_toggled)
        self._ap_group.add(self._ap_switch)
        self._page.add(self._ap_group)
        self.connect("destroy", self._on_ap_destroy)

        # Only the first run, before any report exists, may use the full-page
        # placeholder: once there are rows they stay in place for every
        # refresh, with each row showing its own progress.
        self._placeholder = Adw.StatusPage(
            icon_name="utilities-system-monitor-symbolic",
            title="Checking the setup",
        )
        self._retry = Gtk.Button(label="Try again", halign=Gtk.Align.CENTER)
        self._retry.add_css_class("pill")
        self._retry.connect("clicked", lambda _b: self.refresh())
        self._placeholder.set_child(self._retry)

        self._view = Gtk.Stack(
            transition_type=Gtk.StackTransitionType.CROSSFADE, vexpand=True
        )
        self._view.add_named(self._placeholder, "placeholder")
        self._view.add_named(self._page, "page")
        self.append(self._view)
        self.refresh_ap()

    # -- probing -------------------------------------------------------
    def refresh(self, *, escalate: bool | None = None) -> None:
        # The doctor probe and the AP state change independently: a page
        # refresh must not leave the switch on a stale answer.
        self.refresh_ap()
        if self._busy:
            return
        escalate = self._escalation_for(escalate)
        self._busy = True
        self._pending_escalation = escalate
        self._banner.set_revealed(False)
        self._begin_run()
        self._window.set_status_busy(True)
        threading.Thread(
            target=self._probe_stream, args=(escalate,), daemon=True
        ).start()

    def _begin_run(self) -> None:
        """Paint the starting state without ever blanking an existing report."""
        if not self._has_report:
            # A first run that failed left partial rows in the old model; the
            # retry starts from the same section skeleton, not from them.
            self._model = StatusStream(self._sections)
        self._model.begin()
        if self._has_report:
            self._mark_pending()
        else:
            self._render_skeleton()
        self._window.report_status(self._model.payload(), partial=True)

    def _probe_argv(self, escalate: bool) -> list[str]:
        exe = registry.doctor_bin()
        if not exe:
            raise ProbeError("phone-doctor not found on PATH")
        argv = [exe, "--json-stream"]
        if escalate and os.geteuid() != 0:
            prefix = registry.escalation_prefix()
            if not prefix:
                raise ProbeError("neither sudo nor pkexec is available")
            argv = [*prefix, *argv]
        return argv

    def _probe_stream(self, escalate: bool) -> None:
        try:
            argv = self._probe_argv(escalate)
        except Exception as exc:
            GLib.idle_add(self._apply_error, str(exc))
            return

        saw_done = False
        diagnostic = ""

        def on_line(line: str) -> None:
            nonlocal saw_done, diagnostic
            event = parse_line(line)
            if event is None:
                if line.strip():
                    # stderr is merged into stdout; keep the last line so a
                    # crash has a message instead of a bare exit status.
                    diagnostic = line.strip()
                return
            if event.get("event") == "done":
                saw_done = True
            GLib.idle_add(self._on_event, event)

        try:
            outcome = stream(argv, on_line=on_line, timeout=180)
        except Exception as exc:  # a runner failure is a failed run, not a crash
            GLib.idle_add(self._apply_error, str(exc))
            return

        if saw_done:
            # A non-zero exit is the normal "not ready" verdict; the done event
            # has already been queued and settles the page.
            return
        message = outcome.error or f"phone-doctor exited {outcome.exit_code}"
        if diagnostic:
            message = f"{message}: {diagnostic}"
        GLib.idle_add(self._apply_error, message)

    def refresh_if_idle(self) -> None:
        if not self._busy:
            self.refresh()

    def _escalation_for(self, escalate: bool | None) -> bool:
        """An explicit request wins; otherwise stay as authenticated."""
        return self._escalated if escalate is None else escalate

    # -- access point switch -------------------------------------------
    def refresh_ap(self) -> None:
        """Read the AP state in the background; never block the page."""
        if self._ap_shut or self._ap_probing:
            return
        self._ap_probing = True
        self._ap_switch.set_sensitive(False)
        if not self._ap_acting:
            self._ap_switch.set_subtitle("Checking whether the access point is on…")
        threading.Thread(target=self._read_ap, daemon=True).start()

    def _read_ap(self) -> None:
        on = False
        error = ""
        try:
            on = probe_ap()
        except Exception as exc:  # the row reports any failure, never a traceback
            error = str(exc)
        GLib.idle_add(self._apply_ap, on, error)

    def _apply_ap(self, on: bool, error: str) -> bool:
        self._ap_probing = False
        if self._ap_shut:
            return False
        self._ap_updating = True
        self._ap_switch.set_active(on)
        self._ap_updating = False
        if error:
            self._ap_switch.set_subtitle(f"Could not read the access point: {error}")
        else:
            self._ap_switch.set_subtitle(AP_ON_SUBTITLE if on else AP_OFF_SUBTITLE)
        self._ap_switch.set_sensitive(not self._ap_acting)
        return False

    def _on_ap_toggled(self, row, _pspec) -> None:
        if self._ap_updating or self._ap_acting:
            return
        wanted = row.get_active()
        self._ap_acting = True
        row.set_sensitive(False)
        row.set_subtitle(
            "Bringing the access point up…"
            if wanted
            else "Stopping the access point; the phone link drops by design…"
        )
        if not self._window.start_ap_switch(wanted):
            # The action could not be planned: put the switch back where it was.
            self._ap_acting = False
            self._ap_updating = True
            row.set_active(not wanted)
            self._ap_updating = False
            row.set_sensitive(True)
            row.set_subtitle(AP_ON_SUBTITLE if not wanted else AP_OFF_SUBTITLE)
            self._window.report_error(
                "PhoneLink access point", "could not start the action"
            )

    def ap_action_finished(self) -> None:
        """The run ended: the switch is usable again and the radio is re-probed."""
        self._ap_acting = False
        self.refresh_ap()

    def _on_ap_destroy(self, _widget) -> None:
        self._ap_shut = True

    def _on_authenticate(self, _banner) -> None:
        self.refresh(escalate=True)

    # -- streaming events ----------------------------------------------
    def _on_event(self, event: dict) -> bool:
        change = self._model.apply(event)
        if not change.accepted:
            return False
        if change.kind == "done":
            self._finish()
            return False
        if change.kind == "section":
            if change.new_section:
                self._add_section(change.section)
                self._add_placeholder(change.section)
            return False
        if change.kind == "result":
            self._add_section(change.section)
            self._remove_placeholder(change.section)
            key = (change.section, change.row.cid)
            view = self._rows.get(key)
            if view is None:
                self._add_row(change.row)
            else:
                self._set_row_result(view, change.row)
            self._update_heading(change.section)
            self._update_summary(partial=True)
            self._window.report_status(self._model.payload(), partial=True)
        return False

    def _finish(self) -> None:
        self._busy = False
        self._has_report = True
        self._escalated = self._pending_escalation
        self._window.set_status_busy(False)
        for (section, cid), view in self._rows.items():
            row = self._model.rows.get(section, {}).get(cid)
            if row is not None:
                self._set_row_result(view, row)
        for name in list(self._placeholders):
            self._remove_placeholder(name)
        for section in list(self._section_groups):
            self._update_heading(section)
        self._update_summary(partial=False)
        data = self._model.payload()
        self._window.report_status(data)
        self._show_auth_banner(data)
        self._view.set_visible_child_name("page")

    def _apply_error(self, error: str) -> bool:
        self._busy = False
        self._model.fail(error)
        escalated = self._pending_escalation
        if escalated and not self._is_root:
            # sudo's timestamp is gone or the prompt was declined: drop the
            # stickiness before the banner is drawn so it can offer
            # authentication again.
            self._escalated = False
        self._window.set_status_busy(False)
        if self._has_report:
            # Keep the report that is already on screen. Put the rows back the
            # way they were and say that this run did not finish.
            for (section, cid), view in self._rows.items():
                row = self._model.rows.get(section, {}).get(cid)
                if row is not None:
                    self._set_row_result(view, row)
            for section in list(self._section_groups):
                self._update_heading(section)
            if self._summary_row is not None:
                self._summary_row.set_title("Could not check the setup")
                self._summary_row.set_subtitle(
                    GLib.markup_escape_text(
                        f"{error} — showing the last result "
                        f"({_counts_text(self._model.counts())})"
                    )
                )
                self._set_summary_prefix("dialog-error-symbolic", "error")
            self._window.report_error("Status probe failed", error)
            self._show_auth_banner(self._model.payload())
            self._view.set_visible_child_name("page")
        else:
            # sudo's timestamp is gone or the prompt was declined: drop the
            # stickiness so the banner can offer authentication again.
            self._placeholder.set_title("Could not check the setup")
            self._placeholder.set_description(error)
            self._placeholder.set_icon_name("dialog-error-symbolic")
            self._placeholder.set_child(self._retry)
            self._view.set_visible_child_name("placeholder")
            self._window.report_error("Status probe failed", error)
        return False

    # -- rendering -----------------------------------------------------
    def _clear_findings(self) -> None:
        for group in [self._summary_group, *self._section_groups.values()]:
            if group is not None:
                self._page.remove(group)
        self._summary_group = None
        self._summary_row = None
        self._summary_prefix = None
        self._section_groups.clear()
        self._section_bases.clear()
        self._placeholders.clear()
        self._rows.clear()

    def _render_skeleton(self) -> None:
        self._clear_findings()
        self._build_summary()
        for name in self._sections:
            self._add_section(name)
            self._add_placeholder(name)
        self._update_summary(partial=True)
        self._view.set_visible_child_name("page")

    def _build_summary(self) -> None:
        group = Adw.PreferencesGroup(title="Verdict")
        row = Adw.ActionRow(
            title="Checking the setup",
            subtitle="phone-doctor is looking at the flake, the host and the phone.",
        )
        prefix = _spinner()
        row.add_prefix(prefix)
        button = Gtk.Button(label="Run status", valign=Gtk.Align.CENTER)
        button.connect(
            "clicked",
            lambda _b: self._window.start_action(registry.BY_ID["phone-net-status"]),
        )
        row.add_suffix(button)
        group.add(row)
        self._page.add(group)
        self._summary_group = group
        self._summary_row = row
        self._summary_prefix = prefix

    def _set_summary_prefix(self, icon_name: str, css: str) -> None:
        if self._summary_row is None:
            return
        if self._summary_prefix is not None:
            if isinstance(self._summary_prefix, Gtk.Spinner):
                self._summary_prefix.stop()
            self._summary_row.remove(self._summary_prefix)
        icon = Gtk.Image.new_from_icon_name(icon_name)
        icon.add_css_class(css)
        self._summary_row.add_prefix(icon)
        self._summary_prefix = icon

    def _set_summary_spinner(self) -> None:
        if self._summary_row is None or isinstance(self._summary_prefix, Gtk.Spinner):
            return
        if self._summary_prefix is not None:
            self._summary_row.remove(self._summary_prefix)
        spinner = _spinner()
        self._summary_row.add_prefix(spinner)
        self._summary_prefix = spinner

    def _update_summary(self, *, partial: bool) -> None:
        if self._summary_row is None:
            return
        counts = self._model.counts()
        if partial and not self._model.done:
            reported = self._model.reported_rows()
            total = self._model.total_rows()
            progress = (
                f"{reported} of {total} checks reported"
                if total
                else "starting phone-doctor"
            )
            self._summary_row.set_title("Checking the setup")
            self._summary_row.set_subtitle(f"{progress} · {_counts_text(counts)}")
            self._set_summary_spinner()
            return
        ready = bool(self._model.ready)
        self._summary_row.set_title("ready" if ready else "not ready")
        self._summary_row.set_subtitle(_counts_text(counts))
        self._set_summary_prefix(
            "object-select-symbolic" if ready else "dialog-error-symbolic",
            "success" if ready else "error",
        )

    def _add_section(self, name: str) -> Adw.PreferencesGroup:
        group = self._section_groups.get(name)
        if group is not None:
            return group
        title = SECTION_TITLES.get(name) or name.strip("[]").title()
        group = Adw.PreferencesGroup(title=f"{title} · checking…")
        self._page.add(group)
        self._section_groups[name] = group
        self._section_bases[name] = title
        return group

    def _add_placeholder(self, name: str) -> None:
        group = self._section_groups.get(name)
        if group is None or name in self._placeholders:
            return
        row = Adw.ActionRow(
            title="Checking…",
            subtitle="Waiting for phone-doctor.",
        )
        row.add_prefix(_spinner())
        group.add(row)
        self._placeholders[name] = row

    def _remove_placeholder(self, name: str) -> None:
        row = self._placeholders.pop(name, None)
        group = self._section_groups.get(name)
        if row is not None and group is not None:
            group.remove(row)

    def _add_row(self, result) -> None:
        group = self._add_section(result.section)
        row = Adw.ActionRow()
        row.set_subtitle_selectable(True)
        view = _RowView(row, result.section, result.cid)
        group.add(row)
        self._rows[(result.section, result.cid)] = view
        self._set_row_result(view, result)

    def _set_prefix(self, view: _RowView, widget: Gtk.Widget) -> None:
        if view.prefix is not None:
            if isinstance(view.prefix, Gtk.Spinner):
                view.prefix.stop()
            view.row.remove(view.prefix)
        view.prefix = widget
        view.row.add_prefix(widget)

    def _set_row_pending(self, view: _RowView) -> None:
        view.row.set_subtitle("Checking…")
        self._set_prefix(view, _spinner())
        if view.button is not None:
            view.button.set_sensitive(False)

    def _mark_pending(self) -> None:
        for view in self._rows.values():
            if view.cid in self._model.rows.get(view.section, {}):
                self._set_row_pending(view)
        for section in list(self._section_groups):
            self._update_heading(section)
        self._update_summary(partial=True)

    def _set_row_result(self, view: _RowView, result) -> None:
        focused = view.button is not None and view.button.has_focus()
        view.row.set_title(GLib.markup_escape_text(result.label))
        view.row.set_subtitle(GLib.markup_escape_text(result.detail))
        icon_name, css = STATUS_ICONS.get(result.status, STATUS_ICONS["skip"])
        icon = Gtk.Image.new_from_icon_name(icon_name)
        icon.add_css_class(css)
        self._set_prefix(view, icon)

        for suffix in (view.lock, view.button):
            if suffix is not None:
                view.row.remove(suffix)
        view.lock = None
        view.button = None
        data = {
            "status": result.status,
            "id": result.cid,
            "label": result.label,
            "detail": result.detail,
        }
        button = self._fix_button(data)
        if button is not None:
            # A repair that escalates carries the same lock as on the action
            # pages, so "this asks for a password" is visible before the click.
            if self._needs_root(data):
                lock = _root_lock()
                view.row.add_suffix(lock)
                view.lock = lock
            view.row.add_suffix(button)
            view.button = button
            if focused:
                button.grab_focus()
        elif focused:
            # The repair disappeared (the check now passes): keep keyboard
            # users on the row instead of dropping focus somewhere else.
            view.row.grab_focus()

    def _update_heading(self, section: str) -> None:
        group = self._section_groups.get(section)
        if group is None:
            return
        base = self._section_bases.get(section, section.strip("[]").title())
        rows = self._model.rows.get(section, {})
        if not rows:
            group.set_title(base)
            return
        fails = sum(1 for row in rows.values() if row.status == "fail")
        warns = sum(1 for row in rows.values() if row.status == "warn")
        pending = any(row.pending for row in rows.values())
        if pending:
            title = f"{base} · checking…"
        elif fails:
            title = f"{base} · {fails} failing"
        elif warns:
            title = f"{base} · {warns} warning" + ("" if warns == 1 else "s")
        else:
            title = base
        group.set_title(title)

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
