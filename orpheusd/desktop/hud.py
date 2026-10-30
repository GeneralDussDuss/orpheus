"""The in-game HUD's window handling (Windows): where it goes, how it shows
without taking anything from the game, and when.

It slides in for HUD_SECONDS when the track changes while game mode is on
(outside a game the toast does that job), and whenever the `hud:show` hotkey
fires. The window is Qt-flagged click-through and focus-less, and on top of
that gets WS_EX_NOACTIVATE | WS_EX_TRANSPARENT | WS_EX_LAYERED |
WS_EX_TOOLWINDOW, is raised with SWP_NOACTIVATE and shown with
SW_SHOWNOACTIVATE, so neither a click nor the show itself can pull focus from
a game.

Exclusive-fullscreen games (a D3D swapchain that owns the display, rare now)
are drawn without the desktop compositor, so nothing, this included, can
appear over them. Borderless/flip-model games, which is most modern ones
(Deadlock among them), are composed by DWM and show topmost overlays fine.

config.json: `hud`: "on" (default) | "off"; `hudCorner`: "top-left" (default) |
"top-right" | "bottom-left" | "bottom-right".
"""
from __future__ import annotations

import ctypes
import sys
from ctypes import wintypes
from pathlib import Path

from PySide6.QtCore import QObject, QRect, QTimer, QUrl

from . import gamemode

HERE = Path(__file__).resolve().parent
WINDOWS = sys.platform == "win32"
HUD_SECONDS = 4.0
CORNERS = ("top-left", "top-right", "bottom-left", "bottom-right")

GWL_EXSTYLE = -20
WS_EX_TRANSPARENT, WS_EX_TOOLWINDOW, WS_EX_TOPMOST = 0x20, 0x80, 0x8
WS_EX_LAYERED, WS_EX_NOACTIVATE, WS_EX_APPWINDOW = 0x80000, 0x08000000, 0x40000
HUD_EX = WS_EX_NOACTIVATE | WS_EX_TRANSPARENT | WS_EX_LAYERED | WS_EX_TOOLWINDOW
SW_SHOWNOACTIVATE, SW_HIDE = 4, 0
HWND_TOPMOST = -1
SWP_NOSIZE, SWP_NOMOVE, SWP_NOACTIVATE, SWP_SHOWWINDOW, SWP_FRAMECHANGED = 0x1, 0x2, 0x10, 0x40, 0x20
LWA_ALPHA = 0x2


def settings(cfg: dict | None = None) -> tuple[bool, str]:
    cfg = gamemode.read_config() if cfg is None else cfg
    on = cfg.get("hud", "on") not in ("off", False)
    corner = cfg.get("hudCorner", "top-left")
    return on, corner if corner in CORNERS else "top-left"


def _user32():
    u = ctypes.windll.user32
    u.GetWindowLongPtrW.restype = ctypes.c_ssize_t
    u.GetWindowLongPtrW.argtypes = [wintypes.HWND, ctypes.c_int]
    u.SetWindowLongPtrW.restype = ctypes.c_ssize_t
    u.SetWindowLongPtrW.argtypes = [wintypes.HWND, ctypes.c_int, ctypes.c_ssize_t]
    u.SetWindowPos.argtypes = [wintypes.HWND, wintypes.HWND, ctypes.c_int, ctypes.c_int,
                               ctypes.c_int, ctypes.c_int, ctypes.c_uint]
    u.ShowWindow.argtypes = [wintypes.HWND, ctypes.c_int]
    u.GetLayeredWindowAttributes.argtypes = [wintypes.HWND, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p]
    u.SetLayeredWindowAttributes.argtypes = [wintypes.HWND, wintypes.COLORREF, ctypes.c_ubyte, wintypes.DWORD]
    return u


def ex_style(hwnd: int) -> int:
    return _user32().GetWindowLongPtrW(hwnd, GWL_EXSTYLE) & 0xFFFFFFFF


def make_overlay(hwnd: int) -> int:
    """Give a native window the HUD's extended styles; returns the new ex style."""
    u = _user32()
    ex = u.GetWindowLongPtrW(hwnd, GWL_EXSTYLE) & 0xFFFFFFFF
    was_layered = bool(ex & WS_EX_LAYERED)
    ex = (ex | HUD_EX) & ~WS_EX_APPWINDOW
    u.SetWindowLongPtrW(hwnd, GWL_EXSTYLE, ex)
    if not was_layered:
        # A layered window that never had its attributes set is not drawn at
        # all; full opacity keeps Qt's own per-pixel alpha in charge.
        u.SetLayeredWindowAttributes(hwnd, 0, 255, LWA_ALPHA)
    u.SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0,
                   SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_FRAMECHANGED)
    return ex_style(hwnd)


def show_no_activate(hwnd: int):
    u = _user32()
    u.ShowWindow(hwnd, SW_SHOWNOACTIVATE)
    u.SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW)


def foreground_monitor() -> tuple:
    if not WINDOWS:
        return (0, 0, 0, 0)
    api = gamemode.Win32()
    fg = api.foreground()
    return api.monitor_rect(fg) if fg else (0, 0, 0, 0)


def screen_for(rect: tuple):
    """The QScreen for a Win32 monitor rect (physical pixels). Qt keeps each
    screen's native origin, so the top-left corners match."""
    from PySide6.QtGui import QGuiApplication
    screens = QGuiApplication.screens()
    for s in screens:
        g = s.geometry()
        if (g.x(), g.y()) == (rect[0], rect[1]):
            return s
    cx, cy = (rect[0] + rect[2]) // 2, (rect[1] + rect[3]) // 2
    for s in screens:
        ng = s.geometry()
        dpr = s.devicePixelRatio()
        if ng.x() <= cx < ng.x() + ng.width() * dpr and ng.y() <= cy < ng.y() + ng.height() * dpr:
            return s
    return QGuiApplication.primaryScreen()


def place(area: QRect, w: int, h: int, corner: str) -> tuple[int, int]:
    """Top-left for a w x h window in `corner` of `area`, inset a little, and
    below the very top edge where games keep scores and timers."""
    mx = max(16, area.width() // 80)
    top = max(24, area.height() // 9)
    x = area.x() + mx if "left" in corner else area.x() + area.width() - w - mx
    y = area.y() + top if corner.startswith("top") else area.y() + area.height() - h - max(24, area.height() // 7)
    return x, y


class Hud(QObject):
    def __init__(self, engine, root, parent=None):
        super().__init__(parent)
        from PySide6.QtQml import QQmlComponent
        comp = QQmlComponent(engine, QUrl.fromLocalFile(str(HERE / "qml" / "Hud.qml")))
        self.win = comp.createWithInitialProperties({"engine": root}) if comp.isReady() else None
        if self.win is None:
            print("orpheus-desktop: HUD failed to load:", comp.errorString(), file=sys.stderr)
            return
        self._comp = comp
        self.win.setProperty("_q_showWithoutActivating", True)
        self.hwnd = 0
        self.last = ""
        self.pending = None
        self.started = False
        self._out = QTimer(self, singleShot=True)
        self._out.timeout.connect(self.slide_out)
        self._gone = QTimer(self, singleShot=True)
        self._gone.timeout.connect(self._hide)

    # ---- when ----
    @staticmethod
    def key(t: dict) -> str:
        return str(t.get("id") or f"{t.get('title')}|{t.get('artists')}") if t else ""

    def sync(self, p: dict):
        """A /status player dict (PLAYER_LISTENERS). Same rules as the toast:
        the track loaded at launch is not news, and wait until it plays."""
        t = p.get("track") or {}
        k = self.key(t)
        if not self.started:
            self.started, self.last = True, k
            return
        if k and k != self.last:
            self.last, self.pending = k, t
        if self.pending and p.get("playing"):
            self.pending = None
            if gamemode.active() and settings()[0]:
                self.show()

    # ---- how ----
    def show(self, seconds: float = HUD_SECONDS, monitor: tuple | None = None):
        if self.win is None:
            return
        on, corner = settings()
        if monitor is None:
            det = gamemode.DETECTOR[0] if gamemode.DETECTOR else None
            monitor = det.last_monitor if det and det.active else foreground_monitor()
        screen = screen_for(monitor) if monitor[2] > monitor[0] else None
        from PySide6.QtGui import QGuiApplication
        screen = screen or QGuiApplication.primaryScreen()
        area = screen.geometry()
        self.win.setProperty("corner", corner)
        w, h = self.win.width(), self.win.height()
        x, y = place(area, w, h, corner)
        self.present(x, y, seconds)

    def present(self, x: int, y: int, seconds: float = HUD_SECONDS):
        """Put the window at (x, y) without activating it and slide the card in."""
        self._gone.stop()
        self.win.setPosition(x, y)
        if WINDOWS:
            if not self.hwnd:
                self.win.create()
                self.hwnd = int(self.win.winId())
                make_overlay(self.hwnd)
            if not self.win.isVisible():
                self.win.setVisible(True)         # Qt::Tool + _q_showWithoutActivating: SW_SHOWNOACTIVATE
            show_no_activate(self.hwnd)
        else:
            self.win.setVisible(True)
        self.win.setProperty("shown", True)
        self._out.start(int(seconds * 1000))

    def slide_out(self):
        if self.win is not None:
            self.win.setProperty("shown", False)
            self._gone.start(400)

    def _hide(self):
        if self.win is not None and not self.win.property("shown"):
            self.win.setVisible(False)


HUD: list = []


def install(engine, root) -> Hud | None:
    from .shims import PLAYER_LISTENERS
    h = Hud(engine, root)
    if h.win is None:
        return None
    HUD[:] = [h]
    PLAYER_LISTENERS.append(h.sync)
    return h


def show_now():
    """The hud:show hotkey: the card now, wherever the foreground is."""
    if HUD:
        HUD[0].show()
