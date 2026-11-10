"""The phone-link GTK4/libadwaita application.

The window is a two-pane layout: the sidebar lists the status page and one page
per action group, and the content shows the selected page. Below 720sp the
sidebar collapses into a single pane, which is what keeps it usable in a narrow
window.

No action is implemented here: `phone_link.actions` decides the argv (including
--check, --yes and pkexec) and `phone_link.runner` streams it, so the GUI shows
the same behaviour and the same output as the CLI.
"""

from __future__ import annotations

import sys

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")

from gi.repository import Adw, Gio, Gtk

from phone_link import actions as registry

from .log_window import RunWindow
from .status_page import StatusPage

APP_ID = "org.phonelink.Gui"
# The doctor's findings get their own page, separate from the "status" action
# group; the two titles would otherwise both read "Status".
PAGES = (("doctor", "Status"),) + tuple(
    (group_id, "Status actions" if group_id == "status" else title)
    for group_id, title in registry.GROUPS
)


class ActionsPage(Adw.PreferencesPage):
    """Every action of one group, with its check and variants in a menu."""

    def __init__(self, window, group_id: str, title: str):
        super().__init__()
        group = Adw.PreferencesGroup(title=title)
        self.add(group)
        for action in registry.actions_in(group_id):
            group.add(self._row(window, action))

    def _row(self, window, action: registry.Action) -> Adw.ActionRow:
        row = Adw.ActionRow(title=action.title, subtitle=action.summary)
        row.set_subtitle_selectable(True)

        run = Gtk.Button(label="Run", valign=Gtk.Align.CENTER)
        if action.destructive:
            run.add_css_class("destructive-action")
        run.connect("clicked", lambda _b, a=action: window.start_action(a))
        row.add_suffix(run)

        if action.supports_check or action.variants:
            more = Gtk.MenuButton(
                icon_name="view-more-symbolic", valign=Gtk.Align.CENTER
            )
            more.add_css_class("flat")
            more.set_tooltip_text("More ways to run this")
            more.set_menu_model(self._menu(action))
            row.add_suffix(more)
        return row

    def _menu(self, action: registry.Action) -> Gio.Menu:
        menu = Gio.Menu()
        if action.supports_check:
            menu.append("Check only", f"win.check-{action.id}")
        for index, variant in enumerate(action.variants):
            menu.append(variant.label, f"win.variant-{action.id}-{index}")
        return menu


class Window(Adw.ApplicationWindow):
    def __init__(self, app, *, autostart: bool = True):
        super().__init__(application=app, title="phone-link")
        self.set_default_size(1000, 720)
        self._autostart = autostart

        self._status = StatusPage(self)
        self._stack = Gtk.Stack(
            transition_type=Gtk.StackTransitionType.CROSSFADE, vexpand=True
        )
        self._stack.add_named(self._status, "doctor")
        for group_id, title in registry.GROUPS:
            self._stack.add_named(ActionsPage(self, group_id, title), group_id)

        self._title = Adw.WindowTitle(title="Status")
        self._spinner = Gtk.Spinner()

        refresh = Gtk.Button(icon_name="view-refresh-symbolic")
        refresh.set_tooltip_text("Re-check the setup")
        refresh.connect("clicked", lambda _b: self.refresh_status())

        menu = Gio.Menu()
        menu.append("Refresh status", "win.refresh")
        menu.append("Quit", "app.quit")
        menu_button = Gtk.MenuButton(icon_name="open-menu-symbolic")
        menu_button.set_menu_model(menu)

        header = Adw.HeaderBar()
        header.set_title_widget(self._title)
        header.pack_start(self._spinner)
        header.pack_end(menu_button)
        header.pack_end(refresh)

        self._toasts = Adw.ToastOverlay()
        content = Adw.ToolbarView()
        content.add_top_bar(header)
        content.set_content(self._stack)
        self._toasts.set_child(content)

        self._split = Adw.NavigationSplitView()
        self._split.set_min_sidebar_width(210)
        self._split.set_max_sidebar_width(280)
        self._split.set_sidebar(self._sidebar_page())
        self._split.set_content(Adw.NavigationPage.new(self._toasts, "Status"))
        self.set_content(self._split)

        self._install_breakpoint()
        self._register_actions()
        self._list.connect("row-selected", self._on_row_selected)
        self._list.select_row(self._list.get_row_at_index(0))
        self.connect("map", self._on_map)

    # -- layout --------------------------------------------------------
    def _sidebar_page(self) -> Adw.NavigationPage:
        self._list = Gtk.ListBox()
        self._list.add_css_class("navigation-sidebar")
        self._list.set_selection_mode(Gtk.SelectionMode.SINGLE)
        for page_id, title in PAGES:
            box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
            box.append(
                Gtk.Image.new_from_icon_name(
                    registry.GROUP_ICONS.get(page_id, "dialog-information-symbolic")
                )
            )
            box.append(Gtk.Label(label=title, xalign=0.0))
            self._list.append(Gtk.ListBoxRow(child=box))

        scroller = Gtk.ScrolledWindow(
            vexpand=True, hscrollbar_policy=Gtk.PolicyType.NEVER
        )
        scroller.set_child(self._list)
        sidebar_header = Adw.HeaderBar()
        sidebar_header.set_title_widget(Adw.WindowTitle(title="phone-link"))
        toolbar = Adw.ToolbarView()
        toolbar.add_top_bar(sidebar_header)
        toolbar.set_content(scroller)
        return Adw.NavigationPage.new(toolbar, "phone-link")

    def _install_breakpoint(self) -> None:
        """Collapse to one pane on a narrow window, with a manual fallback."""
        try:
            condition = Adw.BreakpointCondition.parse("max-width: 720sp")
            breakpoint = Adw.Breakpoint.new(condition)
            breakpoint.add_setter(self._split, "collapsed", True)
            self.add_breakpoint(breakpoint)
        except (AttributeError, TypeError):
            self.connect("notify::default-width", self._collapse_by_width)
            self.connect("map", self._collapse_by_width)

    def _collapse_by_width(self, *_args) -> None:
        if self.get_mapped():
            self._split.set_collapsed(self.get_width() <= 720)

    # -- pages ---------------------------------------------------------
    def page_names(self) -> list[str]:
        return [page_id for page_id, _title in PAGES]

    def show_page(self, page_id: str) -> None:
        self._stack.set_visible_child_name(page_id)
        self._title.set_title(dict(PAGES).get(page_id, page_id))
        if self._split.get_collapsed():
            self._split.set_show_content(True)

    def _on_row_selected(self, _listbox, row) -> None:
        if row is None:
            return
        index = row.get_index()
        if 0 <= index < len(PAGES):
            self.show_page(PAGES[index][0])

    def _on_map(self, _window) -> None:
        if self._autostart:
            self._status.refresh()

    def refresh_status(self) -> None:
        self.show_page("doctor")
        self._status.refresh()

    # -- status feedback -----------------------------------------------
    def set_status_busy(self, busy: bool) -> None:
        if busy:
            self._spinner.start()
        else:
            self._spinner.stop()

    def report_status(self, data: dict) -> None:
        counts = data.get("counts", {})
        if data.get("ready"):
            self._title.set_subtitle("ready")
        else:
            self._title.set_subtitle(
                f"not ready ({counts.get('fail', 0)} failing)"
            )

    def report_error(self, heading: str, body: str) -> None:
        self._toasts.add_toast(Adw.Toast(title=f"{heading}: {body}", timeout=8))

    # -- actions -------------------------------------------------------
    def _register_actions(self) -> None:
        refresh = Gio.SimpleAction.new("refresh", None)
        refresh.connect("activate", lambda _a, _p: self.refresh_status())
        self.add_action(refresh)

        for action in registry.ACTIONS:
            if action.supports_check:
                self._add_action(
                    f"check-{action.id}",
                    lambda a=action: self.start_action(a, check=True),
                )
            for index, _variant in enumerate(action.variants):
                self._add_action(
                    f"variant-{action.id}-{index}",
                    lambda a=action, i=index: self.start_variant(a, i),
                )

    def _add_action(self, name: str, callback) -> None:
        simple = Gio.SimpleAction.new(name, None)
        simple.connect("activate", lambda _a, _p: callback())
        self.add_action(simple)

    def start_action(self, action: registry.Action, *, check: bool = False):
        if check and not action.supports_check:
            check = False
        if not check and action.needs_confirm:
            self._confirm(action, check=check, args=())
            return None
        return self._launch(action, check=check, args=())

    def start_variant(self, action: registry.Action, index: int):
        variant = action.variants[index]
        check = variant.check and action.supports_check
        if not check and action.needs_confirm:
            self._confirm(action, check=check, args=variant.args)
            return None
        return self._launch(action, check=check, args=variant.args)

    def _confirm(self, action, *, check: bool, args: tuple[str, ...]) -> None:
        dialog = Adw.MessageDialog(
            transient_for=self,
            heading=action.title,
            body=action.confirm or action.summary,
        )
        dialog.add_response("cancel", "Cancel")
        dialog.add_response("run", "Run")
        dialog.set_response_appearance("run", Adw.ResponseAppearance.DESTRUCTIVE)
        dialog.set_default_response("cancel")
        dialog.set_close_response("cancel")
        dialog.connect(
            "response",
            lambda _dialog, response: (
                self._launch(action, check=check, args=args)
                if response == "run"
                else None
            ),
        )
        dialog.present()

    def _launch(self, action, *, check: bool, args: tuple[str, ...]):
        try:
            argv = registry.plan(
                action, args=args, check=check, assume_yes=True
            )
        except ValueError as exc:
            self.report_error(action.title, str(exc))
            return None
        window = RunWindow(
            self,
            action.title,
            argv,
            on_finished=lambda outcome: self._after_run(action, outcome),
        )
        window.present()
        return window

    def _after_run(self, action, outcome) -> None:
        if outcome.cancelled:
            self._toasts.add_toast(Adw.Toast(title=f"{action.title}: stopped"))
        elif outcome.ok:
            self._toasts.add_toast(Adw.Toast(title=f"{action.title}: done"))
        else:
            self._toasts.add_toast(
                Adw.Toast(title=f"{action.title}: exit {outcome.exit_code}")
            )
        self._status.refresh_if_idle()


class PhoneLinkApp(Adw.Application):
    def __init__(self):
        super().__init__(
            application_id=APP_ID, flags=Gio.ApplicationFlags.DEFAULT_FLAGS
        )

    def do_activate(self) -> None:
        window = self.props.active_window
        if window is None:
            window = Window(self)
        window.present()


def check_registry(expected: list[str]) -> int:
    """Headless check: the table matches bin/, and the toolkit is wired."""
    problems = registry.validate(tuple(expected))
    try:
        gi.require_version("Gtk", "4.0")
        gi.require_version("Adw", "1")
        from gi.repository import Adw as AdwCheck
        from gi.repository import Gtk as GtkCheck

        if GtkCheck.get_major_version() != 4:
            problems.append("GTK 4 is not available")
        if AdwCheck.get_major_version() != 1:
            problems.append("libadwaita 1 is not available")
    except (ImportError, ValueError) as exc:
        problems.append(f"GTK4/libadwaita not importable: {exc}")

    if problems:
        for problem in problems:
            print(f"error: {problem}", file=sys.stderr)
        return 1
    print(
        f"gui registry ok: {len(registry.ACTIONS)} actions, "
        "GTK4 and libadwaita present"
    )
    return 0


def selftest() -> int:
    """Build the real window, every page and a log window, then quit."""
    app = PhoneLinkApp()
    state = {"ok": False, "error": "no activate"}

    def activate(application) -> None:
        try:
            window = Window(application, autostart=False)
            window.present()
            for name in window.page_names():
                window.show_page(name)
            probe_window = RunWindow(window, "selftest", ["true"], autostart=False)
            probe_window.destroy()
            window.close()
            state["ok"] = True
            state["error"] = ""
        except Exception as exc:  # reported by the flake check
            state["error"] = f"{type(exc).__name__}: {exc}"
        application.quit()

    app.connect("activate", activate)
    # Do not forward --selftest: GApplication parses argv and would reject it
    # before emitting activate, which is the hook this selftest needs.
    app.run(["phone-link-gui"])
    if not state["ok"]:
        print(f"selftest failed: {state['error']}", file=sys.stderr)
        return 1
    print("selftest ok: window, every page and the log window construct")
    return 0


def main(argv=None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if "--check-registry" in args:
        expected = [value for value in args if not value.startswith("-")]
        return check_registry(expected)
    if "--selftest" in args:
        return selftest()
    app = PhoneLinkApp()
    return app.run(["phone-link-gui", *args])
