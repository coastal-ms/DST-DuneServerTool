#!/usr/bin/env python3
"""Dune Server Tool — native Linux desktop shell (GTK3 + WebKit2GTK 4.1).

The Linux counterpart to DuneShell.exe. A single-instance window that loads the
local portal in a WebKit2 WebView. The PowerShell backend writes the per-launch
tokenized URL to last-url.txt once its listener binds; this shell polls for that
file, then loads the URL. A small header bar offers Reload and "Open in browser".

Closing the window asks the backend to shut down gracefully
(POST /api/shutdown, carrying the same token via the URL query) UNLESS a
keep-alive flag is present — mirroring the Windows shell's teardown.

Dependencies (Debian/Ubuntu): python3-gi, gir1.2-webkit2-4.1, gir1.2-gtk-3.0.
"""
import os
import sys
import time
import urllib.parse
import urllib.request

import gi
gi.require_version("Gtk", "3.0")
gi.require_version("WebKit2", "4.1")
from gi.repository import Gtk, WebKit2, GLib, Gdk, Gio  # noqa: E402

APP_ID = "tools.layout.DuneServer"
POLL_TIMEOUT_SEC = 60


def _state_dir():
    base = os.environ.get("XDG_STATE_HOME") or os.path.join(
        os.path.expanduser("~"), ".local", "state"
    )
    return os.path.join(base, "DuneServer")


def _last_url_path():
    return os.path.join(_state_dir(), "last-url.txt")


def _keepalive_path():
    return os.path.join(_state_dir(), "keep-alive.flag")


def _read_last_url():
    try:
        with open(_last_url_path(), "r", encoding="utf-8") as fh:
            return fh.read().strip()
    except OSError:
        return ""


_PLACEHOLDER = """<!doctype html><meta charset="utf-8">
<body style="font-family:system-ui,sans-serif;background:#0b0b0f;color:#cfcfd6;
display:flex;align-items:center;justify-content:center;height:100vh;margin:0">
<div>Connecting to Dune&nbsp;Server&nbsp;Tool&hellip;</div></body>"""

_TIMED_OUT = """<!doctype html><meta charset="utf-8">
<body style="font-family:system-ui,sans-serif;background:#0b0b0f;color:#ff6b6b;
padding:2rem;line-height:1.5">
<h2>Dune Server portal did not start</h2>
<p>Timed out waiting for the local portal URL. Check the log at
<code>~/.local/state/DuneServer/dune-server.log</code>.</p></body>"""


class DuneWindow(Gtk.ApplicationWindow):
    def __init__(self, app):
        super().__init__(application=app, title="Dune Server")
        self.set_default_size(1280, 860)
        self.target_url = ""

        header = Gtk.HeaderBar()
        header.set_show_close_button(True)
        header.props.title = "Dune Server"
        self.set_titlebar(header)

        reload_btn = Gtk.Button.new_from_icon_name(
            "view-refresh-symbolic", Gtk.IconSize.BUTTON
        )
        reload_btn.set_tooltip_text("Reload the portal")
        reload_btn.connect("clicked", self._on_reload)
        header.pack_start(reload_btn)

        browser_btn = Gtk.Button.new_with_label("Open in browser")
        browser_btn.set_tooltip_text("Open the portal in your default browser")
        browser_btn.connect("clicked", self._on_open_browser)
        header.pack_end(browser_btn)

        self.webview = WebKit2.WebView()
        self.add(self.webview)
        self.webview.load_html(_PLACEHOLDER, None)

        self.connect("delete-event", self._on_close)

        self._deadline = time.monotonic() + POLL_TIMEOUT_SEC
        GLib.timeout_add(300, self._poll_for_url)

    # --- URL polling --------------------------------------------------------
    def _poll_for_url(self):
        url = _read_last_url()
        if url:
            self.target_url = url
            self.webview.load_uri(url)
            return False  # stop polling
        if time.monotonic() > self._deadline:
            self.webview.load_html(_TIMED_OUT, None)
            return False
        return True  # keep polling

    # --- toolbar actions ----------------------------------------------------
    def _on_reload(self, *_):
        if self.target_url:
            self.webview.load_uri(self.target_url)
        else:
            self.webview.reload()

    def _on_open_browser(self, *_):
        if self.target_url:
            Gtk.show_uri_on_window(self, self.target_url, Gdk.CURRENT_TIME)

    # --- graceful teardown (mirrors DuneShell.exe) --------------------------
    def _on_close(self, *_):
        if not os.path.exists(_keepalive_path()):
            url = self.target_url or _read_last_url()
            if url:
                try:
                    parts = urllib.parse.urlsplit(url)
                    shutdown = urllib.parse.urlunsplit(
                        (parts.scheme, parts.netloc, "/api/shutdown", parts.query, "")
                    )
                    req = urllib.request.Request(
                        shutdown,
                        data=b"{}",
                        method="POST",
                        headers={"Content-Type": "application/json"},
                    )
                    # Tight timeout: the listener tears down before it can reply.
                    urllib.request.urlopen(req, timeout=0.75)
                except Exception:
                    pass
        return False  # allow the window to close


class DuneApp(Gtk.Application):
    def __init__(self):
        super().__init__(
            application_id=APP_ID, flags=Gio.ApplicationFlags.FLAGS_NONE
        )

    def do_activate(self):
        # Single-instance: a second launch just re-focuses the live window.
        win = self.get_active_window()
        if win is None:
            win = DuneWindow(self)
        win.present()


def main():
    return DuneApp().run(sys.argv)


if __name__ == "__main__":
    sys.exit(main())
