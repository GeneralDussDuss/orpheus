"""Game mode: notice a fullscreen game (or a presentation) and keep Orpheus out of its way.

Two signals, polled every two seconds:

  * SHQueryUserNotificationState, Windows' own "is the user busy" answer:
    QUNS_RUNNING_D3D_FULL_SCREEN (exclusive fullscreen D3D), QUNS_BUSY (a
    fullscreen app) and QUNS_PRESENTATION_MODE;
  * the foreground window itself: borderless "fullscreen" games (Deadlock and
    most modern ones, flip-model swapchains) often read as plain QUNS_ACCEPTS,
    so a foreground window that covers its whole monitor, has no caption, and is
    neither the desktop/taskbar nor one of ours counts too.

While it is on, the widget is hidden (a runtime override, nothing is written to
config.json), toasts are skipped, the stage steps back (it is a topmost window)
and nothing of ours takes focus; the in-game HUD (hud.py) is the one thing that
may show, and it never activates. It turns on at once and off only once the
condition has been false for HOLD_S seconds of wall-clock time (not a poll count),
so alt-tab, a Steam/Discord overlay, a loading screen or a toast taking the
foreground does not bring everything back.

config.json `gameMode`: "auto" (default) or "off".
"""
from __future__ import annotations

import ctypes
import json
import os
import sys
import time
from ctypes import wintypes
from dataclasses import dataclass, field
from pathlib import Path

WINDOWS = sys.platform == "win32"
CONFIG = Path(os.environ.get("ORPHEUS_HOME") or Path.home()) / ".config" / "orpheus" / "config.json"

QUNS_NOT_PRESENT, QUNS_BUSY, QUNS_RUNNING_D3D_FULL_SCREEN = 1, 2, 3
QUNS_PRESENTATION_MODE, QUNS_ACCEPTS_NOTIFICATIONS, QUNS_QUIET_TIME, QUNS_APP = 4, 5, 6, 7
QUNS_NAMES = {1: "not present", 2: "busy", 3: "d3d fullscreen", 4: "presentation",
              5: "accepts notifications", 6: "quiet time", 7: "app"}
GAME_STATES = {QUNS_BUSY, QUNS_RUNNING_D3D_FULL_SCREEN, QUNS_PRESENTATION_MODE}

WS_CAPTION = 0x00C00000
GWL_STYLE = -16
MONITOR_DEFAULTTONEAREST = 2
# The desktop, the taskbar and friends cover the monitor too, and are not games.
SHELL_CLASSES = {"Progman", "WorkerW", "Shell_TrayWnd", "Shell_SecondaryTrayWnd",
                 "Windows.UI.Core.CoreWindow", "XamlExplorerHostIslandWindow",
                 "ForegroundStaging", "MultitaskingViewFrame", "TaskSwitcherWnd"}


_READ: list = [None, {}]     # (mtime, size) of config.json, and what it held


def read_config() -> dict:
    """config.json, parsed again only when it changes: game mode asks every 2 s
    and the settings page's Discord line every 3. Treat the result as read-only."""
    try:
        st = CONFIG.stat()
    except OSError:
        return {}
    key = (st.st_mtime_ns, st.st_size)
    if _READ[0] != key:
        try:
            c = json.loads(CONFIG.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return {}                      # mid-write: read it again next time
        _READ[:] = [key, c if isinstance(c, dict) else {}]
    return _READ[1]


def setting(cfg: dict | None = None) -> str:
    v = (read_config() if cfg is None else cfg).get("gameMode", "auto")
    return "off" if v in ("off", False) else "auto"


# ---- Win32, behind a small seam so the logic can be tested with a fake ----------

class _MONITORINFO(ctypes.Structure):
    _fields_ = [("cbSize", wintypes.DWORD), ("rcMonitor", wintypes.RECT),
                ("rcWork", wintypes.RECT), ("dwFlags", wintypes.DWORD)]


class Win32:
    """Read-only questions about the desktop. Nothing here changes a window."""

    def __init__(self):
        u = ctypes.windll.user32
        u.GetForegroundWindow.restype = wintypes.HWND
        u.MonitorFromWindow.restype = wintypes.HMONITOR
        u.MonitorFromWindow.argtypes = [wintypes.HWND, wintypes.DWORD]
        u.GetMonitorInfoW.argtypes = [wintypes.HMONITOR, ctypes.POINTER(_MONITORINFO)]
        u.GetWindowLongW.restype = ctypes.c_long
        u.GetWindowLongW.argtypes = [wintypes.HWND, ctypes.c_int]
        u.GetAncestor.restype = wintypes.HWND
        u.GetAncestor.argtypes = [wintypes.HWND, ctypes.c_uint]
        self.u = u

    def notification_state(self) -> int:
        s = ctypes.c_int(QUNS_ACCEPTS_NOTIFICATIONS)
        if ctypes.windll.shell32.SHQueryUserNotificationState(ctypes.byref(s)) < 0:
            return QUNS_ACCEPTS_NOTIFICATIONS
        return s.value

    def foreground(self) -> int:
        h = self.u.GetForegroundWindow()
        if not h:
            return 0
        return self.u.GetAncestor(h, 2) or h          # GA_ROOT

    def pid(self, hwnd: int) -> int:
        p = wintypes.DWORD()
        self.u.GetWindowThreadProcessId(wintypes.HWND(hwnd), ctypes.byref(p))
        return p.value

    def class_name(self, hwnd: int) -> str:
        b = ctypes.create_unicode_buffer(256)
        self.u.GetClassNameW(wintypes.HWND(hwnd), b, 256)
        return b.value

    def title(self, hwnd: int) -> str:
        b = ctypes.create_unicode_buffer(256)
        self.u.GetWindowTextW(wintypes.HWND(hwnd), b, 256)
        return b.value

    def style(self, hwnd: int) -> int:
        return self.u.GetWindowLongW(wintypes.HWND(hwnd), GWL_STYLE) & 0xFFFFFFFF

    def visible(self, hwnd: int) -> bool:
        return bool(self.u.IsWindowVisible(wintypes.HWND(hwnd))) and not self.u.IsIconic(wintypes.HWND(hwnd))

    def window_rect(self, hwnd: int) -> tuple[int, int, int, int]:
        r = wintypes.RECT()
        self.u.GetWindowRect(wintypes.HWND(hwnd), ctypes.byref(r))
        return r.left, r.top, r.right, r.bottom

    def monitor_rect(self, hwnd: int) -> tuple[int, int, int, int]:
        mon = self.u.MonitorFromWindow(wintypes.HWND(hwnd), MONITOR_DEFAULTTONEAREST)
        mi = _MONITORINFO()
        mi.cbSize = ctypes.sizeof(mi)
        if not mon or not self.u.GetMonitorInfoW(mon, ctypes.byref(mi)):
            return 0, 0, 0, 0
        r = mi.rcMonitor
        return r.left, r.top, r.right, r.bottom

    def exe(self, pid: int) -> str:
        k = ctypes.windll.kernel32
        k.OpenProcess.restype = wintypes.HANDLE
        h = k.OpenProcess(0x1000, False, pid)          # PROCESS_QUERY_LIMITED_INFORMATION
        if not h:
            return ""
        try:
            b = ctypes.create_unicode_buffer(520)
            n = wintypes.DWORD(520)
            if k.QueryFullProcessImageNameW(h, 0, b, ctypes.byref(n)):
                return os.path.basename(b.value)
            return ""
        finally:
            k.CloseHandle(h)


@dataclass
class Verdict:
    active: bool
    reason: str = ""
    state: int = QUNS_ACCEPTS_NOTIFICATIONS
    monitor: tuple = (0, 0, 0, 0)            # the game's monitor, when there is one
    title: str = ""
    exe: str = ""
    details: dict = field(default_factory=dict)


def covers(win: tuple, mon: tuple) -> bool:
    if mon[2] <= mon[0] or mon[3] <= mon[1]:
        return False
    return win[0] <= mon[0] and win[1] <= mon[1] and win[2] >= mon[2] and win[3] >= mon[3]


def assess(api, own_pid: int) -> Verdict:
    """Is a game (or anything else that wants the screen to itself) in front right now?"""
    state = api.notification_state()
    fg = api.foreground()
    if not fg:
        # Nothing in front (the lock screen, a UAC prompt): trust Windows' answer alone.
        on = state in GAME_STATES
        return Verdict(on, f"no foreground window, state {QUNS_NAMES.get(state, state)}" if on else "", state)
    pid = api.pid(fg)
    cls = api.class_name(fg)
    if pid == own_pid:
        # Our own stage is fullscreen and topmost too: it is not a game.
        return Verdict(False, "", state, details={"foreground": "orpheus", "class": cls})
    if cls in SHELL_CLASSES:
        return Verdict(False, "", state, details={"foreground": "shell", "class": cls})
    mon = api.monitor_rect(fg)
    rect = api.window_rect(fg)
    style = api.style(fg)
    full = api.visible(fg) and covers(rect, mon) and (style & WS_CAPTION) != WS_CAPTION
    title = api.title(fg)
    exe = api.exe(pid) if (full or state in GAME_STATES) else ""
    details = {"class": cls, "rect": rect, "monitor": mon, "captioned": (style & WS_CAPTION) == WS_CAPTION}
    if state in GAME_STATES:
        return Verdict(True, QUNS_NAMES[state], state, mon, title, exe, details)
    if full:
        return Verdict(True, "fullscreen window", state, mon, title, exe, details)
    return Verdict(False, "", state, mon, title, "", details)


# ---- the live detector -----------------------------------------------------------

class Detector:
    """Polls `assess` and keeps the answer, with the hysteresis described above.
    `listeners` are called with (active: bool) on every change. Plain Python so
    it can be driven by a test; GameMode below puts it on a QTimer."""

    HOLD_S = 8.0           # seconds the condition must stay false before game mode ends

    def __init__(self, api=None, own_pid: int | None = None, config=setting, clock=time.monotonic):
        self.api = api if api is not None else (Win32() if WINDOWS else None)
        self.own_pid = os.getpid() if own_pid is None else own_pid
        self.config = config
        self.clock = clock
        self.active = False
        self.verdict = Verdict(False)
        self.last_monitor: tuple = (0, 0, 0, 0)
        self._off_since: float | None = None    # when the current run of "no game" began
        self.listeners: list = []

    def poll(self) -> bool:
        if self.api is None or self.config() == "off":
            self.verdict = Verdict(False, "off in config" if self.api is not None else "")
            self._off_since = None
            self._set(False)               # the user's switch is not subject to the hold
            return self.active
        try:
            v = assess(self.api, self.own_pid)
        except Exception as e:             # a window that vanished mid-question, a ctypes hiccup:
            # no information, so change nothing (and do not let it start the off clock).
            self.verdict = Verdict(self.active, f"probe failed: {e}")
            return self.active
        self.verdict = v
        if v.active:
            self._off_since = None
            if v.monitor[2] > v.monitor[0]:
                self.last_monitor = v.monitor
            self._set(True)
        elif self.active:
            now = self.clock()
            if self._off_since is None:
                self._off_since = now
            if now - self._off_since >= self.HOLD_S:
                self._off_since = None
                self._set(False)
        return self.active

    def _set(self, on: bool):
        if on == self.active:
            return
        self.active = on
        name = self.verdict.exe or self.verdict.title or ""
        print(f"orpheus-desktop: game mode {'on' if on else 'off'}"
              + (f" ({self.verdict.reason}{', ' + name if name else ''})" if on else ""), file=sys.stderr)
        for f in list(self.listeners):
            try:
                f(on)
            except Exception as e:      # one bad listener must not stop the rest
                print("orpheus-desktop: game mode listener failed:", e, file=sys.stderr)


DETECTOR: list = []      # the live Detector, once install() has made it


def active() -> bool:
    """Game mode is on right now (for winshell's toasts and the HUD)."""
    return bool(DETECTOR and DETECTOR[0].active)


def install(app, interval_ms: int = 2000):
    """Start polling on the Qt event loop; returns the Detector."""
    from PySide6.QtCore import QTimer
    det = Detector()
    DETECTOR[:] = [det]
    timer = QTimer(app)
    timer.timeout.connect(det.poll)
    timer.start(interval_ms)
    det._timer = timer
    QTimer.singleShot(0, det.poll)
    return det


if __name__ == "__main__":
    # Read-only probe: print what the detector sees, once a second.
    import time
    d = Detector()
    for _ in range(int(sys.argv[1]) if len(sys.argv) > 1 else 5):
        d.poll()
        v = d.verdict
        print(json.dumps({"active": d.active, "reason": v.reason, "state": QUNS_NAMES.get(v.state, v.state),
                          "title": v.title, "exe": v.exe, **{k: v.details[k] for k in v.details}}))
        time.sleep(1)
