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

from gi.repository import Adw, Gio, GObject, Gtk

from phone_link import actions as registry

from .log_window import RunWindow
from .status_page import PROBLEM_FIXES, StatusPage

APP_ID = "org.phonelink.Gui"
# The doctor's findings get their own page, separate from the "status" action
# group; the two titles would otherwise both read "Status".
PAGES = (("doctor", "Status"),) + tuple(
    (group_id, "Status actions" if group_id == "status" else title)
    for group_id, title in registry.GROUPS
)


def action_row(
    window, action: registry.Action, subtitle: str | None = None
) -> Adw.ActionRow:
    """One action as a row: run button, and a menu for its check and variants."""
    row = Adw.ActionRow(
        title=action.title,
        subtitle=action.summary if subtitle is None else subtitle,
    )
    row.set_subtitle_selectable(True)
    lock = root_badge(action)
    if lock is not None:
        row.add_prefix(lock)

    run = Gtk.Button(label="Run", valign=Gtk.Align.CENTER)
    if action.destructive:
        run.add_css_class("destructive-action")
    run.connect("clicked", lambda _b, a=action: window.start_action(a))
    row.add_suffix(run)

    if action.supports_check or action.variants:
        more = Gtk.MenuButton(icon_name="view-more-symbolic", valign=Gtk.Align.CENTER)
        more.add_css_class("flat")
        more.set_tooltip_text("More ways to run this")
        more.set_menu_model(action_menu(action))
        row.add_suffix(more)
    return row


def action_menu(action: registry.Action) -> Gio.Menu:
    menu = Gio.Menu()
    if action.supports_check:
        menu.append("Check only", f"win.check-{action.id}")
    for index, variant in enumerate(action.variants):
        menu.append(variant.label, f"win.variant-{action.id}-{index}")
    return menu


def root_badge(action: registry.Action) -> Gtk.Image | None:
    """A lock for the actions that escalate through pkexec, else None."""
    if not action.root:
        return None
    lock = Gtk.Image.new_from_icon_name("system-lock-screen-symbolic")
    lock.add_css_class("dim-label")
    lock.set_tooltip_text("Needs root: phone-link asks for your password")
    return lock


class ActionsPage(Adw.PreferencesPage):
    """Every action of one group, with its check and variants in a menu."""

    def __init__(self, window, group_id: str):
        super().__init__()
        # The header carries the page name; repeating it as the group's title
        # printed the same words twice.
        group = Adw.PreferencesGroup()
        self.add(group)
        for action in registry.actions_in(group_id):
            group.add(action_row(window, action))


class SearchPage(Gtk.Box):
    """Every action matching the header's search, as one list."""

    def __init__(self, window):
        super().__init__(orientation=Gtk.Orientation.VERTICAL)
        self._window = window
        self._group: Adw.PreferencesGroup | None = None

        self._results = Adw.PreferencesPage()
        self._placeholder = Adw.StatusPage(
            icon_name="system-search-symbolic", title="Search the actions"
        )
        self._stack = Gtk.Stack(
            transition_type=Gtk.StackTransitionType.CROSSFADE, vexpand=True
        )
        self._stack.add_named(self._results, "results")
        self._stack.add_named(self._placeholder, "placeholder")
        self._stack.set_visible_child_name("placeholder")
        self.append(self._stack)

    def search(self, query: str) -> int:
        """Fill the results for `query`; returns how many actions matched."""
        if self._group is not None:
            self._results.remove(self._group)
            self._group = None

        words = query.lower().split()
        if not words:
            self._show(
                "Search the actions",
                f"Filter the {len(registry.ACTIONS)} actions by name or summary.",
            )
            return 0

        groups = dict(registry.GROUPS)
        matches = []
        for action in registry.ACTIONS:
            # "root"/"sudo" make "which actions need privileges?" answerable
            # from the search bar, next to the lock on those rows.
            haystack = " ".join(
                (
                    action.title,
                    action.summary,
                    action.id,
                    groups.get(action.group, ""),
                    "root sudo pkexec" if action.root else "",
                )
            ).lower()
            if all(word in haystack for word in words):
                matches.append(action)
        if not matches:
            self._show("No matching action", f"Nothing matches “{query.strip()}”.")
            return 0

        group = Adw.PreferencesGroup(
            title=f"{len(matches)} matching action" + ("" if len(matches) == 1 else "s")
        )
        for action in matches:
            group.add(
                action_row(
                    self._window,
                    action,
                    subtitle=f"{groups.get(action.group, action.group)} "
                    f"· {action.summary}",
                )
            )
        self._results.add(group)
        self._group = group
        self._stack.set_visible_child_name("results")
        return len(matches)

    def _show(self, title: str, description: str) -> None:
        self._placeholder.set_title(title)
        self._placeholder.set_description(description)
        self._stack.set_visible_child_name("placeholder")


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
        for group_id, _title in registry.GROUPS:
            self._stack.add_named(ActionsPage(self, group_id), group_id)

        self._search_page = SearchPage(self)
        self._stack.add_named(self._search_page, "search")
        self._last_page = PAGES[0][0]
        # What the header subtitle reports; the narrow layout shortens it.
        self._ready: bool | None = None
        self._fails = 0

        self._title = Adw.WindowTitle(title="Status")
        self._spinner = Gtk.Spinner()

        refresh = Gtk.Button(icon_name="view-refresh-symbolic")
        refresh.set_tooltip_text("Re-check the setup")
        refresh.connect("clicked", lambda _b: self.refresh_status())

        menu = Gio.Menu()
        menu.append("Search actions", "win.search")
        menu.append("Refresh status", "win.refresh")
        menu.append("Quit", "app.quit")
        menu_button = Gtk.MenuButton(icon_name="open-menu-symbolic")
        menu_button.set_menu_model(menu)

        self._search_button = Gtk.ToggleButton(icon_name="system-search-symbolic")
        self._search_button.set_tooltip_text("Search the actions (Ctrl+F)")
        self._search_entry = Gtk.SearchEntry(placeholder_text="Search actions")
        self._search_entry.set_hexpand(True)
        self._search_bar = Gtk.SearchBar()
        self._search_bar.set_child(self._search_entry)
        self._search_bar.connect_entry(self._search_entry)
        self._search_button.bind_property(
            "active",
            self._search_bar,
            "search-mode-enabled",
            GObject.BindingFlags.BIDIRECTIONAL | GObject.BindingFlags.SYNC_CREATE,
        )
        self._search_bar.connect("notify::search-mode-enabled", self._on_search_mode)
        self._search_entry.connect("search-changed", self._on_search_changed)

        header = Adw.HeaderBar()
        header.set_title_widget(self._title)
        header.pack_start(self._spinner)
        header.pack_end(menu_button)
        header.pack_end(refresh)
        header.pack_end(self._search_button)

        self._toasts = Adw.ToastOverlay()
        content = Adw.ToolbarView()
        content.add_top_bar(header)
        content.add_top_bar(self._search_bar)
        content.set_content(self._stack)
        self._toasts.set_child(content)

        self._split = Adw.NavigationSplitView()
        self._split.set_min_sidebar_width(210)
        self._split.set_max_sidebar_width(280)
        self._split.set_sidebar(self._sidebar_page())
        self._split.set_content(Adw.NavigationPage.new(self._toasts, "Status"))
        self.set_content(self._split)

        self._install_breakpoint()
        self._split.connect(
            "notify::collapsed", lambda *_args: self._update_subtitle()
        )
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
            box.append(Gtk.Label(label=title, xalign=0.0, hexpand=True))
            if page_id == "doctor":
                # A count next to the sidebar entry, so the window shows at a
                # glance that the setup needs attention from any page.
                self._badge = Gtk.Label(visible=False, xalign=1.0)
                self._badge.add_css_class("caption")
                box.append(self._badge)
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
        title = "Search" if page_id == "search" else dict(PAGES).get(page_id, page_id)
        self._title.set_title(title)
        if page_id != "search":
            self._last_page = page_id
        if self._split.get_collapsed():
            self._split.set_show_content(True)

    def search(self, query: str) -> int:
        """Open the search and fill it; returns how many actions matched."""
        if not self._search_bar.get_search_mode():
            self._search_button.set_active(True)
        self._search_entry.set_text(query)
        return self._search_page.search(query)

    def _on_search_mode(self, bar, _pspec) -> None:
        if bar.get_search_mode():
            self.show_page("search")
            self._search_entry.grab_focus()
            self._search_page.search(self._search_entry.get_text())
        else:
            self._search_entry.set_text("")
            self.show_page(self._last_page)

    def _on_search_changed(self, entry) -> None:
        if self._search_bar.get_search_mode():
            self._search_page.search(entry.get_text())

    def _on_row_selected(self, _listbox, row) -> None:
        if row is None:
            return
        index = row.get_index()
        if not 0 <= index < len(PAGES):
            return
        if self._search_bar.get_search_mode():
            self._search_button.set_active(False)
        self.show_page(PAGES[index][0])

    def _on_map(self, _window) -> None:
        if self._autostart:
            self._status.refresh()

    def refresh_status(self) -> None:
        if self._search_bar.get_search_mode():
            self._search_button.set_active(False)
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
        self._ready = bool(data.get("ready"))
        self._fails = counts.get("fail", 0)
        self._set_badge(self._fails, counts.get("warn", 0))
        self._update_subtitle()

    def _update_subtitle(self) -> None:
        """Name the verdict, shortened when the panes collapse into one."""
        if self._ready is None:
            return
        if self._ready:
            self._title.set_subtitle("ready")
        elif not self._fails:
            self._title.set_subtitle("not ready")
        elif self._split.get_collapsed():
            # "not ready (2 failing)" does not fit beside the header buttons
            # at 430sp; the count is the part that has to survive.
            self._title.set_subtitle(f"{self._fails} failing")
        else:
            self._title.set_subtitle(f"not ready ({self._fails} failing)")

    def _set_badge(self, fails: int, warns: int) -> None:
        for css in ("error", "warning"):
            self._badge.remove_css_class(css)
        if fails:
            self._badge.set_label(str(fails))
            self._badge.set_tooltip_text(f"{fails} failing checks")
            self._badge.add_css_class("error")
            self._badge.set_visible(True)
        elif warns:
            self._badge.set_label(str(warns))
            self._badge.set_tooltip_text(f"{warns} warning" + ("" if warns == 1 else "s"))
            self._badge.add_css_class("warning")
            self._badge.set_visible(True)
        else:
            self._badge.set_visible(False)

    def report_error(self, heading: str, body: str) -> None:
        self._toasts.add_toast(Adw.Toast(title=f"{heading}: {body}", timeout=8))

    # -- actions -------------------------------------------------------
    def _register_actions(self) -> None:
        refresh = Gio.SimpleAction.new("refresh", None)
        refresh.connect("activate", lambda _a, _p: self.refresh_status())
        self.add_action(refresh)

        search = Gio.SimpleAction.new("search", None)
        search.connect(
            "activate", lambda _a, _p: self._search_button.set_active(True)
        )
        self.add_action(search)

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
        for action, accels in (
            ("win.refresh", ["<Primary>r"]),
            ("win.search", ["<Primary>f"]),
            ("app.quit", ["<Primary>q"]),
        ):
            self.set_accels_for_action(action, accels)

    def do_activate(self) -> None:
        window = self.props.active_window
        if window is None:
            window = Window(self)
        window.present()


def check_registry(expected: list[str]) -> int:
    """Headless check: the table matches bin/, and the toolkit is wired."""
    problems = registry.validate(tuple(expected))
    unknown = sorted(
        {name for name in PROBLEM_FIXES.values() if name not in registry.BY_ID}
    )
    if unknown:
        problems.append("fix buttons point at unknown actions: " + ", ".join(unknown))
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
            if window.search("tunnel") < 1:
                raise RuntimeError("the search found nothing for 'tunnel'")
            if root_badge(registry.BY_ID["phone-ap-up"]) is None:
                raise RuntimeError("a root action carries no lock")
            if root_badge(registry.BY_ID["phone-net-status"]) is not None:
                raise RuntimeError("a user action is marked as root")
            status = window._status
            if status._fix_button({"id": "ip_forward", "status": "fail"}) is None:
                raise RuntimeError("a fixable failure has no Fix button")
            if status._fix_button({"id": "flake_update", "status": "fail"}) is not None:
                raise RuntimeError("a manual failure got a Fix button")
            if status._fix_button({"id": "ip_forward", "status": "ok"}) is not None:
                raise RuntimeError("a passing check got a Fix button")
            auth = status._fix_button({"id": "secrets", "status": "fail"})
            if auth is None or auth.get_label() != "Authenticate":
                raise RuntimeError("a secrets failure does not offer Authenticate")
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
    print("selftest ok: window, every page, search and the log window construct")
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
