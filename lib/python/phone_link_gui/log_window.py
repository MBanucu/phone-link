"""One action run in a window: the script's output, streamed and stoppable."""

from __future__ import annotations

import shlex
import threading

from gi.repository import Adw, GLib, Gtk

from phone_link.runner import Outcome, stream


class RunWindow(Adw.Window):
    def __init__(self, parent, title, argv, *, on_finished=None, autostart=True):
        super().__init__(transient_for=parent, title=title)
        self.set_default_size(780, 540)
        self._argv = tuple(argv)
        self._on_finished = on_finished
        self._cancel = threading.Event()
        self._outcome: Outcome | None = None

        self._spinner = Gtk.Spinner()
        self._title = Adw.WindowTitle(title=title, subtitle=shlex.join(self._argv))
        header = Adw.HeaderBar()
        header.set_title_widget(self._title)
        header.pack_start(self._spinner)

        self._copy = Gtk.Button(icon_name="edit-copy-symbolic")
        self._copy.set_tooltip_text("Copy the output")
        self._copy.connect("clicked", self._on_copy)
        header.pack_end(self._copy)

        self._stop = Gtk.Button(icon_name="process-stop-symbolic")
        self._stop.set_tooltip_text("Stop this run")
        self._stop.connect("clicked", self._on_stop)
        header.pack_end(self._stop)

        self._view = Gtk.TextView(
            editable=False,
            monospace=True,
            cursor_visible=False,
            wrap_mode=Gtk.WrapMode.WORD_CHAR,
            top_margin=12,
            bottom_margin=12,
            left_margin=12,
            right_margin=12,
        )
        self._buffer = self._view.get_buffer()
        scroller = Gtk.ScrolledWindow(vexpand=True, hexpand=True)
        scroller.set_child(self._view)

        self._status = Gtk.Label(label="starting…", xalign=0.0)
        self._status.add_css_class("dim-label")
        bar = Gtk.Box(
            orientation=Gtk.Orientation.HORIZONTAL,
            spacing=12,
            margin_top=6,
            margin_bottom=6,
            margin_start=12,
            margin_end=12,
        )
        bar.append(self._status)

        toolbar = Adw.ToolbarView()
        toolbar.add_top_bar(header)
        toolbar.set_content(scroller)
        toolbar.add_bottom_bar(bar)
        self.set_content(toolbar)

        self.connect("close-request", self._on_close)
        if autostart:
            self.start()

    # -- running -------------------------------------------------------
    def start(self) -> None:
        self._spinner.start()
        threading.Thread(target=self._work, daemon=True).start()

    def _work(self) -> None:
        outcome = stream(self._argv, on_line=self._line, cancel=self._cancel)
        GLib.idle_add(self._finish, outcome)

    def _line(self, line: str) -> None:
        # Called from the worker thread; the buffer belongs to the main loop.
        GLib.idle_add(self._append, line)

    def _append(self, line: str) -> bool:
        self._buffer.insert(self._buffer.get_end_iter(), line + "\n")
        self._view.scroll_to_iter(
            self._buffer.get_end_iter(), 0.0, False, 0.0, 0.0
        )
        return False

    def _finish(self, outcome: Outcome) -> bool:
        self._outcome = outcome
        self._spinner.stop()
        self._stop.set_sensitive(False)
        if outcome.cancelled:
            self._status.set_text("stopped")
        elif outcome.error:
            self._status.set_text(f"could not run: {outcome.error}")
        else:
            self._status.set_text(f"exit {outcome.exit_code} · {outcome.duration:.1f} s")
        if self._on_finished is not None:
            self._on_finished(outcome)
        return False

    # -- buttons -------------------------------------------------------
    def _on_stop(self, _button) -> None:
        self._cancel.set()
        self._status.set_text("stopping…")

    def _on_copy(self, _button) -> None:
        start, end = self._buffer.get_bounds()
        text = self._buffer.get_text(start, end, False)
        clipboard = self.get_clipboard()
        for method in ("set_text", "set"):
            setter = getattr(clipboard, method, None)
            if setter is None:
                continue
            try:
                setter(text)
                return
            except TypeError:
                continue

    def _on_close(self, _window) -> bool:
        self._cancel.set()
        return False
