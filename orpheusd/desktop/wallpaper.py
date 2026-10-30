"""Live wallpaper: put a window behind the desktop icons, like Wallpaper Engine.

The WorkerW technique. Sending Progman the undocumented 0x052C makes Explorer
split the desktop into the icon layer (SHELLDLL_DefView) and a separate window
that only paints the wallpaper; a window parented into the gap between the two
draws over the wallpaper and under the icons.

Two layouts exist:

  classic (Windows 10, 11 before 24H2): DefView sits in a top-level WorkerW,
      and the wallpaper is a second top-level WorkerW right behind it. We
      become a child of that second WorkerW.
  raised (11 24H2 and later): DefView and the wallpaper WorkerW are both
      children of Progman, which is WS_EX_NOREDIRECTIONBITMAP. We become a
      layered child of Progman, z-ordered between DefView (above) and the
      WorkerW (below), since a plain child of a no-redirection parent would
      have nothing to draw into.

Either way the window is made WS_CHILD, transparent to the mouse and never
activated, so the icons keep every click. `detach` puts it back as it was and
asks Explorer to repaint the wallpaper. Nothing here touches the wallpaper
setting itself.

QML reaches this through the `Wallpaper` singleton in the OrpheusDesktop module.
"""
from __future__ import annotations

import atexit
import ctypes
import sys
from ctypes import wintypes as W

WINDOWS = sys.platform == "win32"

GWL_STYLE, GWL_EXSTYLE = -16, -20
WS_CHILD, WS_POPUP = 0x40000000, 0x80000000
WS_CAPTION, WS_THICKFRAME, WS_SYSMENU = 0x00C00000, 0x00040000, 0x00080000
WS_MINIMIZEBOX, WS_MAXIMIZEBOX = 0x00020000, 0x00010000
WS_EX_TOPMOST, WS_EX_TRANSPARENT, WS_EX_TOOLWINDOW = 0x8, 0x20, 0x80
WS_EX_LAYERED, WS_EX_APPWINDOW, WS_EX_NOACTIVATE = 0x80000, 0x40000, 0x08000000
SWP_NOSIZE, SWP_NOMOVE, SWP_NOZORDER, SWP_NOACTIVATE = 0x1, 0x2, 0x4, 0x10
SWP_FRAMECHANGED, SWP_SHOWWINDOW = 0x20, 0x40
SW_SHOWNOACTIVATE = 4
LWA_ALPHA = 0x2
SMTO_NORMAL = 0
SPI_GETDESKWALLPAPER, SPI_SETDESKWALLPAPER = 0x73, 0x14
SPIF_SENDCHANGE = 0x2
MONITOR_DEFAULTTONEAREST = 2

if WINDOWS:
    u32 = ctypes.WinDLL("user32", use_last_error=True)
    LONG_PTR = ctypes.c_ssize_t
    u32.FindWindowW.restype = W.HWND
    u32.FindWindowW.argtypes = [W.LPCWSTR, W.LPCWSTR]
    u32.FindWindowExW.restype = W.HWND
    u32.FindWindowExW.argtypes = [W.HWND, W.HWND, W.LPCWSTR, W.LPCWSTR]
    u32.SendMessageTimeoutW.restype = W.LPARAM
    u32.SendMessageTimeoutW.argtypes = [W.HWND, W.UINT, W.WPARAM, W.LPARAM, W.UINT, W.UINT,
                                        ctypes.POINTER(ctypes.c_size_t)]
    u32.GetWindowLongPtrW.restype = LONG_PTR
    u32.GetWindowLongPtrW.argtypes = [W.HWND, ctypes.c_int]
    u32.SetWindowLongPtrW.restype = LONG_PTR
    u32.SetWindowLongPtrW.argtypes = [W.HWND, ctypes.c_int, LONG_PTR]
    u32.SetParent.restype = W.HWND
    u32.SetParent.argtypes = [W.HWND, W.HWND]
    u32.GetParent.restype = W.HWND
    u32.GetParent.argtypes = [W.HWND]
    u32.SetWindowPos.argtypes = [W.HWND, W.HWND, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int, W.UINT]
    u32.MapWindowPoints.argtypes = [W.HWND, W.HWND, ctypes.c_void_p, W.UINT]
    u32.MonitorFromWindow.restype = W.HMONITOR
    u32.MonitorFromWindow.argtypes = [W.HWND, W.DWORD]
    u32.GetWindowRect.argtypes = [W.HWND, ctypes.POINTER(W.RECT)]
    u32.IsWindow.argtypes = [W.HWND]
    u32.ShowWindow.argtypes = [W.HWND, ctypes.c_int]
    u32.SetLayeredWindowAttributes.argtypes = [W.HWND, W.COLORREF, W.BYTE, W.DWORD]
    u32.SystemParametersInfoW.argtypes = [W.UINT, W.UINT, ctypes.c_void_p, W.UINT]
    u32.EnumWindows.argtypes = [ctypes.WINFUNCTYPE(W.BOOL, W.HWND, W.LPARAM), W.LPARAM]

    class MONITORINFO(ctypes.Structure):
        _fields_ = [("cbSize", W.DWORD), ("rcMonitor", W.RECT), ("rcWork", W.RECT), ("dwFlags", W.DWORD)]

    u32.GetMonitorInfoW.argtypes = [W.HMONITOR, ctypes.POINTER(MONITORINFO)]


def _h(v) -> int:
    return int(v or 0)


def find_host():
    """(parent, below_this, layout) for a wallpaper window, or None.

    `parent` is the window to become a child of; in the raised layout
    `below_this` is DefView, which the wallpaper must sit under."""
    progman = u32.FindWindowW("Progman", None)
    if not progman:
        return None
    done = ctypes.c_size_t()
    defview = u32.FindWindowExW(progman, None, "SHELLDLL_DefView", None)
    if defview:
        # Raised layout. 0x052C (re)creates the wallpaper WorkerW, which would
        # land on top of anything already placed, so only ask when it is missing.
        if not u32.FindWindowExW(progman, None, "WorkerW", None):
            u32.SendMessageTimeoutW(progman, 0x052C, 0xD, 0x1, SMTO_NORMAL, 1000, ctypes.byref(done))
        if u32.FindWindowExW(progman, None, "WorkerW", None):
            return _h(progman), _h(defview), "raised"
    else:
        u32.SendMessageTimeoutW(progman, 0x052C, 0, 0, SMTO_NORMAL, 1000, ctypes.byref(done))

    # Classic: find the top-level window that holds DefView; the WorkerW after it
    # in z-order is the wallpaper.
    found = []

    @ctypes.WINFUNCTYPE(W.BOOL, W.HWND, W.LPARAM)
    def visit(hwnd, _):
        if u32.FindWindowExW(hwnd, None, "SHELLDLL_DefView", None):
            worker = u32.FindWindowExW(None, hwnd, "WorkerW", None)
            if worker:
                found.append(_h(worker))
                return False
        return True

    u32.EnumWindows(visit, 0)
    if found:
        return found[0], 0, "classic"
    # Icons are off, or Explorer did not split: Progman itself paints the
    # wallpaper, and with no DefView there is nothing to stay under.
    return _h(progman), _h(defview), "progman"


class _Saved:
    def __init__(self, hwnd):
        self.style = u32.GetWindowLongPtrW(hwnd, GWL_STYLE)
        self.exstyle = u32.GetWindowLongPtrW(hwnd, GWL_EXSTYLE)
        self.parent = _h(u32.GetParent(hwnd))
        r = W.RECT()
        u32.GetWindowRect(hwnd, ctypes.byref(r))
        self.rect = (r.left, r.top, r.right - r.left, r.bottom - r.top)
        self.host = 0
        self.layout = ""


ATTACHED: dict[int, _Saved] = {}


def _monitor_rect(hwnd):
    info = MONITORINFO()
    info.cbSize = ctypes.sizeof(MONITORINFO)
    if not u32.GetMonitorInfoW(u32.MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST), ctypes.byref(info)):
        return None
    r = info.rcMonitor
    return r.left, r.top, r.right - r.left, r.bottom - r.top


def attach(hwnd: int) -> str:
    """Move `hwnd` behind the desktop icons, covering the monitor it is on now.
    Returns the layout used ("raised", "classic", "progman"), or "" on failure."""
    if not WINDOWS or not hwnd:
        return ""
    if hwnd in ATTACHED:
        return ATTACHED[hwnd].layout
    mon = _monitor_rect(hwnd)
    host = find_host()
    if not mon or not host:
        return ""
    parent, defview, layout = host
    saved = _Saved(hwnd)
    saved.host, saved.layout = parent, layout

    style = (saved.style & ~(WS_POPUP | WS_CAPTION | WS_THICKFRAME | WS_SYSMENU
                             | WS_MINIMIZEBOX | WS_MAXIMIZEBOX)) | WS_CHILD
    ex = (saved.exstyle & ~(WS_EX_TOPMOST | WS_EX_APPWINDOW)) | WS_EX_TRANSPARENT | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW
    if layout == "raised":
        ex |= WS_EX_LAYERED
    u32.SetWindowLongPtrW(hwnd, GWL_STYLE, style)
    u32.SetWindowLongPtrW(hwnd, GWL_EXSTYLE, ex)
    if ex & WS_EX_LAYERED:
        u32.SetLayeredWindowAttributes(hwnd, 0, 255, LWA_ALPHA)
    if not u32.SetParent(hwnd, parent):
        u32.SetWindowLongPtrW(hwnd, GWL_STYLE, saved.style)
        u32.SetWindowLongPtrW(hwnd, GWL_EXSTYLE, saved.exstyle)
        return ""
    ATTACHED[hwnd] = saved

    # Screen coordinates -> the host's client coordinates (the host spans the
    # whole virtual screen, which can start left of or above 0,0).
    pt = (W.POINT * 1)(W.POINT(mon[0], mon[1]))
    u32.MapWindowPoints(None, parent, pt, 1)
    after = defview if layout == "raised" and defview else 0
    flags = SWP_NOACTIVATE | SWP_FRAMECHANGED | SWP_SHOWWINDOW | (0 if after else SWP_NOZORDER)
    u32.SetWindowPos(hwnd, after, pt[0].x, pt[0].y, mon[2], mon[3], flags)
    u32.ShowWindow(hwnd, SW_SHOWNOACTIVATE)
    ensure_order(hwnd)
    return layout


def ensure_order(hwnd: int):
    """Raised layout: keep the wallpaper WorkerW under us. Explorer recreates it
    now and then (a wallpaper change, a slideshow step) and the new one lands on top."""
    saved = ATTACHED.get(hwnd)
    if not saved or saved.layout != "raised":
        return
    worker = u32.FindWindowExW(saved.host, None, "WorkerW", None)
    above = worker and u32.FindWindowExW(saved.host, worker, None, None)
    # Children enumerate top first: anything after the WorkerW is below it.
    while above:
        if _h(above) == hwnd:
            u32.SetWindowPos(worker, hwnd, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE)
            return
        above = u32.FindWindowExW(saved.host, above, None, None)


def detach(hwnd: int, refresh: bool = True) -> bool:
    """Undo `attach`: a top-level window again, where it was, styles restored."""
    saved = ATTACHED.pop(hwnd, None)
    if saved is None:
        return False
    if u32.IsWindow(hwnd):
        u32.SetParent(hwnd, saved.parent or None)
        u32.SetWindowLongPtrW(hwnd, GWL_STYLE, saved.style)
        u32.SetWindowLongPtrW(hwnd, GWL_EXSTYLE, saved.exstyle)
        x, y, w, h = saved.rect
        u32.SetWindowPos(hwnd, 0, x, y, w, h, SWP_NOACTIVATE | SWP_NOZORDER | SWP_FRAMECHANGED)
    if refresh:
        refresh_wallpaper()
    return True


def host_alive(hwnd: int) -> bool:
    """False once Explorer has gone away under an attached window."""
    saved = ATTACHED.get(hwnd)
    return bool(saved and u32.IsWindow(saved.host) and u32.IsWindow(hwnd)
                and _h(u32.GetParent(hwnd)) == saved.host)


def refresh_wallpaper():
    """Set the current wallpaper again, without saving anything, so Explorer
    repaints whatever the visualizer left on the wallpaper window."""
    if not WINDOWS:
        return
    buf = ctypes.create_unicode_buffer(1024)
    if u32.SystemParametersInfoW(SPI_GETDESKWALLPAPER, len(buf), buf, 0) and buf.value:
        u32.SystemParametersInfoW(SPI_SETDESKWALLPAPER, 0, buf, SPIF_SENDCHANGE)


def detach_all():
    hadany = bool(ATTACHED)
    for hwnd in list(ATTACHED):
        detach(hwnd, refresh=False)
    if hadany:
        refresh_wallpaper()


atexit.register(detach_all)


# ---- QML ---------------------------------------------------------------------

try:
    from PySide6.QtCore import QObject, QTimer, Signal, Slot
    from PySide6.QtGui import QGuiApplication, QWindow
    from PySide6.QtQml import QmlElement, QmlSingleton
except ImportError:  # pragma: no cover - only the QML side needs Qt
    QObject = None

if QObject is not None:
    QML_IMPORT_NAME = "OrpheusDesktop"
    QML_IMPORT_MAJOR_VERSION = 1

    def _hwnd(window) -> int:
        if window is None:
            return 0
        if not isinstance(window, QWindow):
            # QML hands windows over as QObject; rewrap the same object.
            from shiboken6 import Shiboken
            window = Shiboken.wrapInstance(Shiboken.getCppPointer(window)[0], QWindow)
        return int(window.winId())

    @QmlElement
    @QmlSingleton
    class Wallpaper(QObject):
        """`Wallpaper.attach(window)` / `Wallpaper.detach(window)` from QML.
        `lost` fires when Explorer restarts under an attached window, which
        takes the window's native handle with it: recreate the window."""
        lost = Signal()

        def __init__(self, parent=None):
            super().__init__(parent)
            self._watch = QTimer(self)
            self._watch.setInterval(2000)
            self._watch.timeout.connect(self._check)
            app = QGuiApplication.instance()
            if app is not None:
                app.aboutToQuit.connect(detach_all)

        @Slot(QObject, result=str)
        def attach(self, window):
            layout = attach(_hwnd(window)) if WINDOWS else ""
            if layout:
                self._watch.start()
            else:
                print("orpheus-desktop: could not put the visualizer on the wallpaper", file=sys.stderr)
            return layout

        @Slot(QObject, result=bool)
        def detach(self, window):
            try:
                hwnd = _hwnd(window)
            except RuntimeError:  # the window is already gone
                return False
            ok = detach(hwnd)
            if not ATTACHED:
                self._watch.stop()
            return ok

        def _check(self):
            dead = [h for h in ATTACHED if not host_alive(h)]
            for h in dead:
                ATTACHED.pop(h, None)
            if dead:
                self.lost.emit()
            for h in ATTACHED:
                ensure_order(h)
            if not ATTACHED:
                self._watch.stop()
