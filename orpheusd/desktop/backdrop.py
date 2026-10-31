"""Glass mode on Windows: a blurred, see-through window that still takes every click.

Why it is not just a translucent colour. QQuickWindow.setColor() with alpha asks
for an alpha buffer; Qt then presents through DirectComposition (a premultiplied
swapchain on a DComp visual, qrhid3d11.cpp) and, because the window is
frameless, also makes it WS_EX_LAYERED (QWindowsWindow::setWindowLayered).
Windows hit-tests a layered window by the alpha of its redirection bitmap, and a
DComp-presented window never draws into that bitmap, so the whole window read
as clear and clicks fell through it. That is why Windows was opaque.

The fix keeps the alpha buffer and the DComp swapchain, and takes WS_EX_LAYERED
back off: a native event filter edits the new style in WM_STYLECHANGING, so
Qt's later attempts (show, opacity, flag changes) do not stick either. Without
WS_EX_LAYERED, hit-testing is the plain rectangle (WM_NCHITTEST -> HTCLIENT), so
fully transparent pixels still belong to the window. The DComp visual blends
over the window's redirection surface, which Qt's DwmEnableBlurBehindWindow
call (empty blur region) makes see-through, and under that DWM draws the
backdrop asked for here.

Backdrops (desktop.json "glassBackdrop", or ORPHEUS_GLASS_BACKDROP):
  blur     SetWindowCompositionAttribute ACCENT_ENABLE_BLURBEHIND. Undocumented
           but what most frameless apps use; works on WS_POPUP windows and does
           not lag when dragged. The default.
  acrylic  the same call with ACCENT_ENABLE_ACRYLICBLURBEHIND: blur plus noise
           and luminosity; can lag while dragging or resizing.
  system   DWMWA_SYSTEMBACKDROP_TYPE = DWMSBT_TRANSIENTWINDOW (documented
           acrylic, Windows 11 22H2+) with the frame extended over the client
           area. May draw nothing on a frameless (WS_POPUP) window.
  mica     DWMSBT_MAINWINDOW, same caveats.

The tint is the theme background at shims.GLASS_ALPHA, painted by the QML
(Color.background carries it), so every backdrop reads the same.

The alpha buffer is chosen when the native window is created, so a live toggle
re-creates an existing window (destroy + show with its signals held, so the QML
never sees it hide). Off Windows, or under -platform offscreen, everything here
is a no-op apart from that bookkeeping.
"""
from __future__ import annotations

import ctypes
import os
import sys
from ctypes import wintypes

from PySide6.QtCore import QAbstractNativeEventFilter, QEvent, QObject, QTimer, Slot
from PySide6.QtGui import QGuiApplication, QPlatformSurfaceEvent, QWindow
from PySide6.QtQml import QmlElement, QmlSingleton

WINDOWS = sys.platform == "win32"

GWL_EXSTYLE = -20
WS_EX_LAYERED = 0x00080000
WS_EX_TRANSPARENT = 0x00000020
WS_EX_NOREDIRECTIONBITMAP = 0x00200000
WM_STYLECHANGING = 0x007C
SWP_FLAGS = 0x0001 | 0x0002 | 0x0004 | 0x0010 | 0x0020   # NOSIZE|NOMOVE|NOZORDER|NOACTIVATE|FRAMECHANGED

WCA_ACCENT_POLICY = 19
ACCENT_DISABLED, ACCENT_ENABLE_BLURBEHIND, ACCENT_ENABLE_ACRYLICBLURBEHIND = 0, 3, 4
DWMWA_USE_IMMERSIVE_DARK_MODE = 20
DWMWA_SYSTEMBACKDROP_TYPE = 38
DWMSBT_AUTO, DWMSBT_NONE, DWMSBT_MAINWINDOW, DWMSBT_TRANSIENTWINDOW = 0, 1, 2, 3

MODES = ("blur", "acrylic", "system", "mica")


class ACCENT_POLICY(ctypes.Structure):
    _fields_ = [("AccentState", ctypes.c_int), ("AccentFlags", ctypes.c_int),
                ("GradientColor", ctypes.c_uint), ("AnimationId", ctypes.c_int)]


class WINCOMPATTRDATA(ctypes.Structure):
    _fields_ = [("Attribute", ctypes.c_int), ("Data", ctypes.c_void_p), ("SizeOfData", ctypes.c_size_t)]


class MARGINS(ctypes.Structure):
    _fields_ = [("cxLeftWidth", ctypes.c_int), ("cxRightWidth", ctypes.c_int),
                ("cyTopHeight", ctypes.c_int), ("cyBottomHeight", ctypes.c_int)]


class STYLESTRUCT(ctypes.Structure):
    _fields_ = [("styleOld", wintypes.DWORD), ("styleNew", wintypes.DWORD)]


def say(*a):
    print("orpheus-desktop: glass:", *a, file=sys.stderr, flush=True)


if WINDOWS:
    _user32 = ctypes.WinDLL("user32", use_last_error=True)
    _dwm = ctypes.WinDLL("dwmapi")
    _user32.GetWindowLongPtrW.restype = ctypes.c_ssize_t
    _user32.GetWindowLongPtrW.argtypes = [wintypes.HWND, ctypes.c_int]
    _user32.SetWindowLongPtrW.restype = ctypes.c_ssize_t
    _user32.SetWindowLongPtrW.argtypes = [wintypes.HWND, ctypes.c_int, ctypes.c_ssize_t]
    _user32.SetWindowPos.argtypes = [wintypes.HWND, wintypes.HWND, ctypes.c_int, ctypes.c_int,
                                     ctypes.c_int, ctypes.c_int, ctypes.c_uint]
    _dwm.DwmSetWindowAttribute.argtypes = [wintypes.HWND, wintypes.DWORD, ctypes.c_void_p, wintypes.DWORD]
    _dwm.DwmSetWindowAttribute.restype = ctypes.c_long
    _dwm.DwmExtendFrameIntoClientArea.argtypes = [wintypes.HWND, ctypes.POINTER(MARGINS)]
    _dwm.DwmExtendFrameIntoClientArea.restype = ctypes.c_long
    try:
        _swca = _user32.SetWindowCompositionAttribute
        _swca.argtypes = [wintypes.HWND, ctypes.POINTER(WINCOMPATTRDATA)]
        _swca.restype = wintypes.BOOL
    except AttributeError:   # pragma: no cover - present since Windows 7
        _swca = None


def ex_style(hwnd: int) -> int:
    return int(_user32.GetWindowLongPtrW(hwnd, GWL_EXSTYLE)) & 0xFFFFFFFF if WINDOWS and hwnd else 0


def strip_layered(hwnd: int) -> bool:
    """Take WS_EX_LAYERED off. True if it was on. Never on a window that passes
    input through (WS_EX_TRANSPARENT needs layered to work)."""
    ex = ex_style(hwnd)
    if not ex & WS_EX_LAYERED or ex & WS_EX_TRANSPARENT:
        return False
    _user32.SetWindowLongPtrW(hwnd, GWL_EXSTYLE, ex & ~WS_EX_LAYERED)
    _user32.SetWindowPos(hwnd, None, 0, 0, 0, 0, SWP_FLAGS)
    return True


def _accent(hwnd: int, state: int, tint_abgr: int = 0) -> bool:
    if _swca is None:
        return False
    pol = ACCENT_POLICY(state, 0, tint_abgr, 0)
    data = WINCOMPATTRDATA(WCA_ACCENT_POLICY, ctypes.cast(ctypes.byref(pol), ctypes.c_void_p),
                           ctypes.sizeof(pol))
    return bool(_swca(hwnd, ctypes.byref(data)))


def _dwm_int(hwnd: int, attr: int, value: int) -> int:
    v = ctypes.c_int(value)
    return int(_dwm.DwmSetWindowAttribute(hwnd, attr, ctypes.byref(v), ctypes.sizeof(v)))


def _extend(hwnd: int, on: bool) -> int:
    m = MARGINS(-1, -1, -1, -1) if on else MARGINS(0, 0, 0, 0)
    return int(_dwm.DwmExtendFrameIntoClientArea(hwnd, ctypes.byref(m)))


def apply(hwnd: int, on: bool, mode: str = "blur", dark: bool = True, tint_abgr: int = 0x10000000) -> dict:
    """Put a backdrop behind `hwnd` (or take it away). Returns what each call said,
    for logs and glass_check.py. HRESULTs are 0 on success."""
    out: dict = {"mode": mode if on else "off"}
    if not WINDOWS or not hwnd:
        return out
    if on:
        out["layered_stripped"] = strip_layered(hwnd)
    out["dark"] = _dwm_int(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, 1 if dark else 0)
    want_accent = {"blur": ACCENT_ENABLE_BLURBEHIND, "acrylic": ACCENT_ENABLE_ACRYLICBLURBEHIND}.get(mode) if on else None
    want_sbt = {"system": DWMSBT_TRANSIENTWINDOW, "mica": DWMSBT_MAINWINDOW}.get(mode) if on else None
    # Only one source of backdrop at a time; clear the other kind.
    out["accent"] = _accent(hwnd, want_accent or ACCENT_DISABLED, tint_abgr if want_accent else 0)
    out["backdrop"] = _dwm_int(hwnd, DWMWA_SYSTEMBACKDROP_TYPE, want_sbt or DWMSBT_NONE)
    out["extend"] = _extend(hwnd, bool(want_sbt))
    return out


class LayeredGuard(QAbstractNativeEventFilter):
    """Keeps WS_EX_LAYERED off the windows in `hwnds`: Qt sets it again on a
    show, an opacity change or new flags, and each of those goes through
    SetWindowLongPtr, which sends WM_STYLECHANGING first. The new style is
    edited in place there, before Windows applies it."""

    def __init__(self):
        super().__init__()
        self.hwnds: set[int] = set()
        self.blocked = 0          # for glass_check.py and logs

    def nativeEventFilter(self, event_type, message):
        if event_type != b"windows_generic_MSG" or not self.hwnds:
            return False, 0
        addr = int(message)
        # MSG: hwnd (pointer), then UINT message. Read only that until it matters.
        if ctypes.c_uint.from_address(addr + ctypes.sizeof(ctypes.c_void_p)).value != WM_STYLECHANGING:
            return False, 0
        msg = wintypes.MSG.from_address(addr)
        if ctypes.c_int32(int(msg.wParam or 0) & 0xFFFFFFFF).value != GWL_EXSTYLE:
            return False, 0
        hwnd = int(msg.hWnd or 0)
        if hwnd in self.hwnds and msg.lParam:
            ss = STYLESTRUCT.from_address(int(msg.lParam))
            if ss.styleNew & WS_EX_LAYERED and not ss.styleNew & WS_EX_TRANSPARENT:
                ss.styleNew &= ~WS_EX_LAYERED
                self.blocked += 1
        return False, 0


GUARD: list = []


def guard() -> LayeredGuard | None:
    """The app-wide filter, installed on first use (Windows platform only)."""
    if not WINDOWS or QGuiApplication.platformName() != "windows":
        return None
    if not GUARD:
        g = LayeredGuard()
        QGuiApplication.instance().installNativeEventFilter(g)
        GUARD.append(g)
    return GUARD[0]


def backdrop_mode() -> str:
    m = os.environ.get("ORPHEUS_GLASS_BACKDROP", "")
    if not m:
        from .shims import load_prefs
        m = str(load_prefs().get("glassBackdrop", "") or "")
    return m if m in MODES else "blur"


def _as_window(obj):
    """QML hands windows over as QObject; rewrap the same object as a QWindow."""
    if obj is None or isinstance(obj, QWindow):
        return obj
    from shiboken6 import Shiboken
    from PySide6.QtQuick import QQuickWindow
    return Shiboken.wrapInstance(Shiboken.getCppPointer(obj)[0], QQuickWindow)


def _has_alpha(w) -> bool:
    return w.format().alphaBufferSize() > 0


QML_IMPORT_NAME = "OrpheusDesktop"
QML_IMPORT_MAJOR_VERSION = 1


class _Watch(QObject):
    """Per-window event filter: native window made or about to go."""

    def __init__(self, owner: "Backdrop", w):
        super().__init__(w)
        self.owner, self.w = owner, w

    def eventFilter(self, obj, ev):
        t = ev.type()
        if t == QEvent.Type.PlatformSurface:
            kind = ev.surfaceEventType()
            if kind == QPlatformSurfaceEvent.SurfaceEventType.SurfaceCreated:
                self.owner._created(self.w)
            elif kind == QPlatformSurfaceEvent.SurfaceEventType.SurfaceAboutToBeDestroyed:
                self.owner._forget_hwnd(self.w)
        elif t == QEvent.Type.Show:
            self.owner._refresh(self.w)
        return False


@QmlElement
@QmlSingleton
class Backdrop(QObject):
    """`Backdrop.track(window)` from FloatingWindow.qml. Follows Color.glass:
    glass windows get the backdrop and keep their clicks; the rest are left
    exactly as Qt makes them."""

    def __init__(self, parent=None):
        super().__init__(parent)
        self._windows: list = []          # (QWindow, _Watch)
        self._hwnd: dict[int, int] = {}   # id(window) -> hwnd the guard holds
        self._made: set[int] = set()      # id(window) of those with a native window
        self._color = None
        BACKDROP[:] = [self]

    def _theme(self):
        from .shims import THEME
        c = THEME[0] if THEME else None
        if c is not None and c is not self._color:
            self._color = c
            c.glassChanged.connect(lambda: QTimer.singleShot(0, self._sync_all))
            c.colorsChanged.connect(self._tint_changed)
        return c

    def glass(self) -> bool:
        c = self._theme()
        return bool(c and c.property("glass"))

    def _dark(self) -> bool:
        c = self._theme()
        if c is None:
            return True
        bg = c.property("background")
        return (0.2126 * bg.redF() + 0.7152 * bg.greenF() + 0.0722 * bg.blueF()) <= 0.5

    @Slot(QObject)
    def track(self, obj):
        w = _as_window(obj)
        if w is None or any(x is w for x, _ in self._windows):
            return
        watch = _Watch(self, w)
        w.installEventFilter(watch)
        self._windows.append((w, watch))
        w.destroyed.connect(lambda *_: self._drop(w))
        self._theme()
        if self._native(w):
            self._created(w)

    def _drop(self, w):
        self._windows = [(x, f) for x, f in self._windows if x is not w]
        self._forget_hwnd(w)

    def _native(self, w) -> bool:
        """The native window exists. PySide keeps QWindow.handle() private, so
        this follows the PlatformSurface events, and a shown window has one."""
        return id(w) in self._made or w.isVisible()

    def _forget_hwnd(self, w):
        self._made.discard(id(w))
        hwnd = self._hwnd.pop(id(w), 0)
        g = GUARD[0] if GUARD else None
        if g and hwnd:
            g.hwnds.discard(hwnd)

    def _created(self, w):
        """The native window exists (shown or not yet). With an alpha buffer it
        must not stay layered, glass on or off."""
        self._made.add(id(w))
        g = guard()
        if g is None:
            return
        try:
            hwnd = int(w.winId())
        except RuntimeError:
            return
        if _has_alpha(w):
            g.hwnds.add(hwnd)
            self._hwnd[id(w)] = hwnd
            strip_layered(hwnd)
        self._refresh(w)

    def _refresh(self, w):
        if guard() is None or not self._native(w):
            return
        hwnd = int(w.winId())
        on = self.glass() and _has_alpha(w)
        r = apply(hwnd, on, backdrop_mode(), self._dark())
        if on and ex_style(hwnd) & WS_EX_LAYERED:
            say(f"window {hwnd:#x} is still layered after stripping: {r}")

    def _tint_changed(self):
        # Only the dark/light frame hint follows the theme; cheap, but not per glide frame.
        dark = self._dark()
        if getattr(self, "_last_dark", None) == dark:
            return
        self._last_dark = dark
        if self.glass() and guard() is not None:
            for w, _ in self._windows:
                if self._native(w):
                    _dwm_int(int(w.winId()), DWMWA_USE_IMMERSIVE_DARK_MODE, 1 if dark else 0)

    def _sync_all(self):
        """Color.glass changed and the QML has given the windows their new colour
        (and so their new requested format). A window whose native one was made
        with the other kind of buffer is made again."""
        for w, _ in list(self._windows):
            try:
                self._sync(w)
            except RuntimeError:     # the window went away meanwhile
                pass

    def _sync(self, w):
        if not self._native(w):
            return                   # made later, from the requested format
        want = w.requestedFormat().alphaBufferSize() > 0
        if want != _has_alpha(w):
            recreate(w)
        else:
            self._refresh(w)


BACKDROP: list = []


def recreate(w):
    """Make `w`'s native window again (the alpha buffer is fixed at creation).
    Its signals are held meanwhile, so the QML never sees the window hide:
    Library.qml closes itself on visibleChanged(false)."""
    visible, active, geo = w.isVisible(), w.isActive(), w.geometry()
    w.blockSignals(True)
    try:
        w.destroy()
        if visible:
            w.setGeometry(geo)
            w.setVisible(True)
            if active:
                w.requestActivate()
    finally:
        w.blockSignals(False)
