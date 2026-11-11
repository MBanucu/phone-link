"""sudo's askpass helper: one dialog, then sudo remembers the authentication.

sudo runs this with SUDO_ASKPASS set and reads the password from its stdout.
Nothing is cached here: sudo keeps its own timestamp, which is what makes the
following root actions run without asking again.
"""

from __future__ import annotations

import sys

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")

from gi.repository import Adw, Gtk  # noqa: E402

APP_ID = "org.phonelink.Askpass"


class Askpass(Adw.Application):
    def __init__(self) -> None:
        super().__init__(application_id=APP_ID)
        self.cancelled = True

    def do_activate(self) -> None:
        window = Adw.ApplicationWindow(application=self, title="phone-link")
        window.set_resizable(False)
        window.set_default_size(400, -1)

        prompt = Gtk.Label(label="phone-link needs your password", xalign=0, wrap=True)
        prompt.add_css_class("title-4")
        hint = Gtk.Label(
            label="sudo keeps it for a few minutes, so the next root action "
            "does not ask again.",
            xalign=0,
            wrap=True,
        )
        hint.add_css_class("dim-label")

        self._entry = Gtk.PasswordEntry(show_peek_icon=True)
        self._entry.props.activates_default = True

        cancel = Gtk.Button(label="Cancel")
        cancel.connect("clicked", lambda _button: self._finish(False))
        submit = Gtk.Button(label="Authenticate")
        submit.add_css_class("suggested-action")
        submit.connect("clicked", lambda _button: self._finish(True))

        buttons = Gtk.Box(spacing=6, halign=Gtk.Align.END)
        buttons.append(cancel)
        buttons.append(submit)

        body = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        body.set_margin_top(18)
        body.set_margin_bottom(18)
        body.set_margin_start(18)
        body.set_margin_end(18)
        for child in (prompt, hint, self._entry, buttons):
            body.append(child)

        view = Adw.ToolbarView()
        view.add_top_bar(Adw.HeaderBar())
        view.set_content(body)
        window.set_content(view)
        window.set_default_widget(submit)
        window.present()
        self._entry.grab_focus()

    def _finish(self, submit: bool) -> None:
        if submit:
            password = self._entry.get_text()
            if not password:
                return
            # sudo reads exactly this line from our stdout.
            print(password, flush=True)
            self.cancelled = False
        self.quit()


def main() -> int:
    app = Askpass()
    app.run([APP_ID])
    return 1 if app.cancelled else 0


if __name__ == "__main__":
    sys.exit(main())
