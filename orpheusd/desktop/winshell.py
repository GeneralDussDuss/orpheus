"""Windows 11 shell integration: what makes Orpheus look like a native player.

  * taskbar thumbnail toolbar: previous / play-pause / next under the player's
    taskbar preview, the play/pause glyph following the player, and the taskbar
    button's progress bar following the track position;
  * a quiet toast on track change (title, artist, cover art), skipped while an
    Orpheus window has focus or a fullscreen app or game is running, and off when
    `toasts` is false in ~/.config/orpheus/config.json;
  * a jump list (taskbar / Start right-click): Play/Pause, Next, Visualizer, Player.

All of it is plain COM and WinRT through ctypes: no comtypes, pywin32 or winrt
packages. The app gets its own AppUserModelID so the taskbar button, jump list,
toasts and the Start-menu shortcut are one app rather than "pythonw".
Off Windows every entry point here is a no-op.
"""
from __future__ import annotations

import ctypes
import hashlib
import json
import os
import sys
from ctypes import POINTER, Structure, byref, c_int, c_long, c_uint, c_ulonglong, c_ushort, c_void_p, c_wchar
from ctypes import wintypes
from pathlib import Path
from xml.sax.saxutils import escape

from PySide6.QtCore import QAbstractNativeEventFilter, QObject, QPointF, QRectF, Qt, QUrl
from PySide6.QtGui import QColor, QGuiApplication, QIcon, QImage, QPainter, QPixmap, QPolygonF

WINDOWS = sys.platform == "win32"
AUMID = "Orpheus.Desktop"
PLAYER_TITLE = "Orpheus"          # Library.qml's window
CONFIG = Path.home() / ".config" / "orpheus" / "config.json"
SHORTCUT = Path(os.environ.get("APPDATA", "")) / "Microsoft" / "Windows" / "Start Menu" / "Programs" / "Orpheus.lnk"

# Thumbnail buttons: (id, glyph, tooltip, action for __main__.fire)
BUTTONS = [(0x4F01, "prev", "Previous", "control:previous"),
           (0x4F02, "play", "Play", "control:toggle"),
           (0x4F03, "next", "Next", "control:next")]
TOGGLE_ID = 0x4F02

WM_COMMAND, WM_NCDESTROY = 0x0111, 0x0082
SUBCLASS_ID = 0x4F00
SUBCLASSPROC = ctypes.WINFUNCTYPE(ctypes.c_ssize_t, wintypes.HWND, c_uint, wintypes.WPARAM, wintypes.LPARAM,
                                  ctypes.c_size_t, ctypes.c_size_t)
THBN_CLICKED = 0x1800
THB_ICON, THB_TOOLTIP, THB_FLAGS = 0x2, 0x4, 0x8
TBPF_NOPROGRESS, TBPF_NORMAL, TBPF_PAUSED = 0x0, 0x2, 0x8
QUNS_ACCEPTS_NOTIFICATIONS = 5
SM_CXSMICON = 49


def log(*a):
    print("orpheus-desktop: winshell:", *a, file=sys.stderr)


# ---- COM through ctypes ---------------------------------------------------------

class GUID(Structure):
    _fields_ = [("d1", wintypes.DWORD), ("d2", wintypes.WORD), ("d3", wintypes.WORD), ("d4", ctypes.c_ubyte * 8)]


def guid(s: str) -> GUID:
    g = GUID()
    if ctypes.windll.ole32.CLSIDFromString(ctypes.c_wchar_p(s), byref(g)) < 0:
        raise ValueError(s)
    return g


class PROPERTYKEY(Structure):
    _fields_ = [("fmtid", GUID), ("pid", wintypes.DWORD)]


class PROPVARIANT(Structure):
    # vt, three reserved words, then a pointer-sized union: 16 bytes on x86, 24 on x64.
    _fields_ = [("vt", c_ushort), ("r1", c_ushort), ("r2", c_ushort), ("r3", c_ushort),
                ("p", c_void_p), ("pad", c_void_p)]


class THUMBBUTTON(Structure):
    _fields_ = [("dwMask", wintypes.DWORD), ("iId", c_uint), ("iBitmap", c_uint), ("hIcon", c_void_p),
                ("szTip", c_wchar * 260), ("dwFlags", wintypes.DWORD)]


VT_LPWSTR = 31
CLSCTX_INPROC_SERVER = 1
IID_IUnknown = "{00000000-0000-0000-C000-000000000046}"


def hr_ok(hr: int, what: str) -> int:
    if hr < 0:
        raise OSError(f"{what}: HRESULT 0x{hr & 0xFFFFFFFF:08X}")
    return hr


def vcall(obj, index: int, argtypes=(), *args) -> int:
    """Call method `index` of a COM interface pointer, returning the raw HRESULT."""
    vtbl = ctypes.cast(c_void_p(obj), POINTER(POINTER(c_void_p)))[0]
    return ctypes.WINFUNCTYPE(c_long, c_void_p, *argtypes)(vtbl[index])(obj, *args)


class Com:
    """An owned interface pointer: Release()d when dropped."""

    def __init__(self, ptr: int):
        self.ptr = ptr

    def __call__(self, index, argtypes=(), *args) -> int:
        return vcall(self.ptr, index, argtypes, *args)

    def qi(self, iid: str) -> "Com":
        out = c_void_p()
        hr_ok(self(0, (POINTER(GUID), POINTER(c_void_p)), byref(guid(iid)), byref(out)), f"QueryInterface {iid}")
        return Com(out.value)

    def __del__(self):
        if self.ptr:
            try:
                vcall(self.ptr, 2)
            except Exception:
                pass
            self.ptr = None


def create(clsid: str, iid: str) -> Com:
    out = c_void_p()
    hr_ok(ctypes.windll.ole32.CoCreateInstance(byref(guid(clsid)), None, CLSCTX_INPROC_SERVER,
                                               byref(guid(iid)), byref(out)), f"CoCreateInstance {clsid}")
    return Com(out.value)


def com_init():
    ctypes.windll.ole32.CoInitializeEx(None, 0x2)  # STA; S_FALSE / RPC_E_CHANGED_MODE are fine: Qt got there first


# ---- WinRT through ctypes -------------------------------------------------------

class HString:
    def __init__(self, s: str):
        self.h = c_void_p()
        n = len(s.encode("utf-16-le")) // 2
        hr_ok(ctypes.windll.combase.WindowsCreateString(ctypes.c_wchar_p(s), c_uint(n), byref(self.h)),
              "WindowsCreateString")

    def __del__(self):
        if self.h:
            ctypes.windll.combase.WindowsDeleteString(self.h)


def rt_factory(cls: str, iid: str) -> Com:
    out = c_void_p()
    name = HString(cls)
    hr_ok(ctypes.windll.combase.RoGetActivationFactory(name.h, byref(guid(iid)), byref(out)),
          f"RoGetActivationFactory {cls}")
    return Com(out.value)


def rt_activate(cls: str) -> Com:
    out = c_void_p()
    name = HString(cls)
    hr_ok(ctypes.windll.combase.RoActivateInstance(name.h, byref(out)), f"RoActivateInstance {cls}")
    return Com(out.value)


# ---- glyphs ---------------------------------------------------------------------

def light_theme() -> bool:
    """The taskbar and jump list follow the *system* theme, not the apps one."""
    try:
        import winreg
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER,
                            r"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize") as k:
            return bool(winreg.QueryValueEx(k, "SystemUsesLightTheme")[0])
    except OSError:
        return False


def glyph(kind: str, size: int, color: QColor | None = None) -> QImage:
    """Transport glyphs in the Segoe MDL2 manner: solid, rounded, centred."""
    if color is None:
        color = QColor("#1b1b1b") if light_theme() else QColor("#ffffff")
    img = QImage(size, size, QImage.Format.Format_ARGB32)
    img.fill(Qt.GlobalColor.transparent)
    p = QPainter(img)
    p.setRenderHint(QPainter.RenderHint.Antialiasing)
    p.setPen(Qt.PenStyle.NoPen)
    p.setBrush(color)
    s = float(size)

    def tri(x0, x1, h):           # x0 is the flat side, x1 the point
        p.drawPolygon(QPolygonF([QPointF(x0 * s, (0.5 - h) * s), QPointF(x1 * s, 0.5 * s),
                                 QPointF(x0 * s, (0.5 + h) * s)]))

    def bar(x0, x1, y0=0.22, y1=0.78):
        r = (x1 - x0) * s * 0.3
        p.drawRoundedRect(QRectF(x0 * s, y0 * s, (x1 - x0) * s, (y1 - y0) * s), r, r)

    if kind == "play":
        tri(0.28, 0.80, 0.31)
    elif kind == "pause":
        bar(0.25, 0.42)
        bar(0.58, 0.75)
    elif kind == "next":
        tri(0.18, 0.64, 0.28)
        bar(0.66, 0.80)
    elif kind == "prev":
        tri(0.82, 0.36, 0.28)
        bar(0.20, 0.34)
    elif kind == "viz":
        for i, h in enumerate((0.30, 0.56, 0.42, 0.62)):
            bar(0.14 + i * 0.19, 0.27 + i * 0.19, 0.5 - h / 2 + 0.1, 0.5 + h / 2 + 0.1)
    p.end()
    return img


# ---- taskbar: thumbnail toolbar + progress --------------------------------------

CLSID_TaskbarList = "{56FDF344-FD6D-11d0-958A-006097C9A090}"
IID_ITaskbarList3 = "{EA1AFB91-9E28-4B86-90E9-9E9F8A5EEFAF}"
# ITaskbarList3 vtable slots
HrInit, SetProgressValue, SetProgressState, ThumbBarAddButtons, ThumbBarUpdateButtons = 3, 9, 10, 15, 16


class Taskbar:
    def __init__(self, fire):
        self.fire = fire
        self.tbl: Com | None = None
        self.hwnds: set[int] = set()       # player windows whose buttons are in place
        self.playing = False
        self.progress = (TBPF_NOPROGRESS, 0, 0)
        self.icons: dict[tuple, int] = {}  # (glyph, size, light) -> HICON, kept for the app's life
        self.last_hr: dict[str, int] = {}
        self.subclassed: set[int] = set()
        self._proc = None
        ctypes.windll.comctl32.DefSubclassProc.restype = ctypes.c_ssize_t
        user32 = ctypes.windll.user32
        user32.RegisterWindowMessageW.restype = c_uint
        self.wm_created = user32.RegisterWindowMessageW("TaskbarButtonCreated")

    def _list(self) -> Com:
        if self.tbl is None:
            com_init()
            tbl = create(CLSID_TaskbarList, IID_ITaskbarList3)
            hr_ok(tbl(HrInit), "ITaskbarList3::HrInit")
            self.tbl = tbl
        return self.tbl

    def _icon(self, kind: str) -> int:
        size = ctypes.windll.user32.GetSystemMetrics(SM_CXSMICON) or 16
        key = (kind, size, light_theme())
        if key not in self.icons:
            self.icons[key] = int(glyph(kind, size).toHICON())
        return self.icons[key]

    def _buttons(self):
        arr = (THUMBBUTTON * len(BUTTONS))()
        for b, (bid, kind, tip, _) in zip(arr, BUTTONS):
            if bid == TOGGLE_ID:
                kind, tip = ("pause", "Pause") if self.playing else ("play", "Play")
            b.dwMask = THB_ICON | THB_TOOLTIP | THB_FLAGS
            b.iId = bid
            b.hIcon = self._icon(kind)
            b.szTip = tip
            b.dwFlags = 0  # THBF_ENABLED
        return arr

    def add(self, hwnd: int) -> bool:
        """Put the buttons on `hwnd`. Add works once per taskbar button, so if it
        has them already (a repeat TaskbarButtonCreated), update them instead."""
        user32 = ctypes.windll.user32
        for m in (self.wm_created, WM_COMMAND):  # only matters if we run elevated
            user32.ChangeWindowMessageFilterEx(wintypes.HWND(hwnd), c_uint(m), 1, None)
        self._subclass(hwnd)
        tbl, arr = self._list(), self._buttons()
        argt = (wintypes.HWND, c_uint, POINTER(THUMBBUTTON))
        hr = tbl(ThumbBarAddButtons, argt, hwnd, len(BUTTONS), arr)
        self.last_hr["add"] = hr
        if hr < 0:
            hr = tbl(ThumbBarUpdateButtons, argt, hwnd, len(BUTTONS), arr)
            self.last_hr["update"] = hr
        if hr < 0:
            return False
        self.hwnds.add(hwnd)
        self._set_progress(hwnd)
        return True

    def sync(self, p: dict):
        """Called with every /status poll."""
        self._find()
        playing = bool(p.get("playing"))
        if playing != self.playing:
            self.playing = playing
            for h in list(self.hwnds):
                arr = self._buttons()
                hr = self._list()(ThumbBarUpdateButtons, (wintypes.HWND, c_uint, POINTER(THUMBBUTTON)),
                                  h, len(BUTTONS), arr)
                self.last_hr["update"] = hr
        dur = float(p.get("duration") or 0)
        pos = max(0.0, min(float(p.get("position") or 0), dur))
        if not p.get("track") or dur <= 0:
            state = TBPF_NOPROGRESS
        elif playing:
            state = TBPF_NORMAL
        elif p.get("paused"):
            state = TBPF_PAUSED
        else:
            state = TBPF_NOPROGRESS
        progress = (state, int(pos * 1000), int(dur * 1000))
        if progress != self.progress:
            self.progress = progress
            for h in list(self.hwnds):
                self._set_progress(h)

    def _set_progress(self, hwnd: int):
        state, done, total = self.progress
        tbl = self._list()
        self.last_hr["state"] = tbl(SetProgressState, (wintypes.HWND, c_int), hwnd, state)
        if state != TBPF_NOPROGRESS:
            self.last_hr["value"] = tbl(SetProgressValue, (wintypes.HWND, c_ulonglong, c_ulonglong),
                                        hwnd, done, max(total, 1))

    def _find(self):
        """Pick up a player window that was shown (or recreated) since the last poll,
        in case its TaskbarButtonCreated came before we were listening; drop hidden ones,
        so showing them again re-adds the buttons."""
        visible = set()
        for w in QGuiApplication.topLevelWindows():
            if w.title() == PLAYER_TITLE and w.isVisible():
                visible.add(int(w.winId()))
        self.hwnds &= visible
        for h in visible - self.hwnds:
            self.add(h)

    @staticmethod
    def is_player(hwnd: int) -> bool:
        buf = ctypes.create_unicode_buffer(64)
        ctypes.windll.user32.GetWindowTextW(wintypes.HWND(hwnd), buf, 64)
        pid = wintypes.DWORD()
        ctypes.windll.user32.GetWindowThreadProcessId(wintypes.HWND(hwnd), byref(pid))
        return buf.value == PLAYER_TITLE and pid.value == os.getpid()

    def on_message(self, msg) -> bool:
        """From the app's native event filter: Explorer (re)made a taskbar button."""
        if msg.message == self.wm_created:
            hwnd = int(msg.hWnd or 0)
            if self.is_player(hwnd):
                self.hwnds.discard(hwnd)
                self.add(hwnd)
        return False

    def _subclass(self, hwnd: int):
        """Qt keeps WM_COMMAND from its native event filters, so the button clicks
        are caught with a window subclass instead (comctl32, safe to stack)."""
        if hwnd in self.subclassed:
            return
        if self._proc is None:
            self._proc = SUBCLASSPROC(self._wndproc)   # kept: Windows holds the pointer
        if ctypes.windll.comctl32.SetWindowSubclass(wintypes.HWND(hwnd), self._proc, SUBCLASS_ID, 0):
            self.subclassed.add(hwnd)

    def _wndproc(self, hwnd, msg, wparam, lparam, _id, _ref):
        try:
            if msg == WM_COMMAND and (wparam >> 16) & 0xFFFF == THBN_CLICKED:
                for b, _, _, action in BUTTONS:
                    if b == wparam & 0xFFFF:
                        self.fire(action)
                        return 0
            elif msg == WM_NCDESTROY:
                ctypes.windll.comctl32.RemoveWindowSubclass(wintypes.HWND(hwnd), self._proc, SUBCLASS_ID)
                self.subclassed.discard(hwnd)
                self.hwnds.discard(hwnd)
        except Exception as e:
            log("thumbnail button:", e)
        return ctypes.windll.comctl32.DefSubclassProc(wintypes.HWND(hwnd), msg, wintypes.WPARAM(wparam),
                                                      wintypes.LPARAM(lparam))


# ---- toasts ---------------------------------------------------------------------

IID_IXmlDocument = "{F7F3A506-1E87-42D6-BCFB-B8C809FA5494}"
IID_IXmlDocumentIO = "{6CD0E74E-EE65-4489-9EBF-CA43E87BA637}"
IID_IToastNotificationFactory = "{04124B20-82C6-4229-B109-FD9ED4662B53}"
IID_IToastNotificationManagerStatics = "{50AC103F-D235-4598-BBEF-98FE4D1A3AD4}"
IID_IToastNotification2 = "{9DFB9FD1-143A-490E-90BF-B9FBA7132DE7}"


def toasts_enabled() -> bool:
    try:
        return bool(json.loads(CONFIG.read_text(encoding="utf-8")).get("toasts", True))
    except (OSError, ValueError, AttributeError):
        return True


def quiet_now() -> str:
    """Why a toast should not show right now, or '' if it may."""
    # Game mode first, so toasts and the rest of game mode agree: it also covers
    # borderless games, which Windows' notification state often calls "accepts".
    # With gameMode off, Windows' own answer below still holds.
    from . import gamemode
    if gamemode.active():
        return "game mode (a fullscreen game is in front)"
    user32 = ctypes.windll.user32
    user32.GetForegroundWindow.restype = c_void_p
    fg = user32.GetForegroundWindow()
    if fg:
        pid = wintypes.DWORD()
        user32.GetWindowThreadProcessId(wintypes.HWND(fg), byref(pid))
        if pid.value == os.getpid():
            return "an Orpheus window has focus"
    state = c_int(QUNS_ACCEPTS_NOTIFICATIONS)
    if ctypes.windll.shell32.SHQueryUserNotificationState(byref(state)) >= 0 \
            and state.value != QUNS_ACCEPTS_NOTIFICATIONS:
        return f"notification state {state.value} (fullscreen, presentation or quiet hours)"
    return ""


class WinToast:
    """Windows.UI.Notifications through raw WinRT. The AUMID is registered under
    HKCU\\Software\\Classes\\AppUserModelId, which gives an unpackaged app its name
    and icon in toasts without a COM activator."""

    def __init__(self, icon_png: Path | None):
        register_aumid(icon_png)
        ctypes.windll.combase.RoInitialize(0)  # STA; already-initialised is fine
        statics = rt_factory("Windows.UI.Notifications.ToastNotificationManager",
                             IID_IToastNotificationManagerStatics)
        out, aumid = c_void_p(), HString(AUMID)   # an HString must outlive the call
        hr_ok(statics(7, (c_void_p, POINTER(c_void_p)), aumid.h, byref(out)),
              "CreateToastNotifierWithId")
        self.notifier = Com(out.value)
        self.factory = rt_factory("Windows.UI.Notifications.ToastNotification", IID_IToastNotificationFactory)

    def setting(self) -> int:
        """0 enabled, 1 off for this app, 2 off for the user, 3 policy, 4 manifest."""
        v = c_int(-1)
        hr_ok(self.notifier(8, (POINTER(c_int),), byref(v)), "IToastNotifier::get_Setting")
        return v.value

    def show(self, xml: str) -> int:
        doc = rt_activate("Windows.Data.Xml.Dom.XmlDocument")
        text, tag, group = HString(xml), HString("now"), HString("orpheus")
        hr_ok(doc.qi(IID_IXmlDocumentIO)(6, (c_void_p,), text.h), "XmlDocument::LoadXml")
        xdoc = doc.qi(IID_IXmlDocument)
        out = c_void_p()
        hr_ok(self.factory(6, (c_void_p, POINTER(c_void_p)), xdoc.ptr, byref(out)), "CreateToastNotification")
        toast = Com(out.value)
        # One tag and group: each track's toast replaces the last in the Action Centre.
        t2 = toast.qi(IID_IToastNotification2)
        t2(6, (c_void_p,), tag.h)       # put_Tag
        t2(8, (c_void_p,), group.h)   # put_Group
        return hr_ok(self.notifier(6, (c_void_p,), toast.ptr), "IToastNotifier::Show")


def register_aumid(icon_png: Path | None):
    import winreg
    with winreg.CreateKey(winreg.HKEY_CURRENT_USER, rf"Software\Classes\AppUserModelId\{AUMID}") as k:
        winreg.SetValueEx(k, "DisplayName", 0, winreg.REG_SZ, "Orpheus")
        if icon_png and icon_png.exists():
            winreg.SetValueEx(k, "IconUri", 0, winreg.REG_SZ, str(icon_png))


def toast_xml(title: str, artist: str, album: str, art: Path | None) -> str:
    image = (f'<image placement="appLogoOverride" src="{escape(art.as_uri())}"/>' if art else "")
    return ('<toast duration="short"><visual><binding template="ToastGeneric">'
            f'<text hint-maxLines="1">{escape(title)}</text>'
            f'<text hint-maxLines="1">{escape(artist)}</text>'
            + (f'<text placement="attribution">{escape(album)}</text>' if album else "")
            + image + '</binding></visual><audio silent="true"/></toast>')


class Toaster(QObject):
    def __init__(self, tray=None, icon_png: Path | None = None, parent=None):
        super().__init__(parent)
        from PySide6.QtNetwork import QNetworkAccessManager
        self.tray = tray
        self.net = QNetworkAccessManager(self)
        self.started = False
        self.last = ""
        self.pending: dict | None = None
        self.shown = 0
        self.last_reason = ""
        try:
            from orpheusd.system import CACHE_DIR
            self.art_dir = CACHE_DIR / "toast-art"
        except Exception:
            import tempfile
            self.art_dir = Path(tempfile.gettempdir()) / "orpheus-toast-art"
        try:
            self.win: WinToast | None = WinToast(icon_png)
        except Exception as e:
            log("Windows toasts unavailable, using the tray:", e)
            self.win = None

    @staticmethod
    def key(t: dict) -> str:
        if not t:
            return ""
        a = t.get("artists") or ""
        return str(t.get("id") or f"{t.get('title')}|{a}")

    def sync(self, p: dict):
        t = p.get("track") or {}
        k = self.key(t)
        if not self.started:      # whatever is loaded at launch is not news
            self.started, self.last = True, k
            return
        if k and k != self.last:
            self.last, self.pending = k, t
        # The status can say "not playing" for a moment while the next track loads.
        if self.pending and p.get("playing"):
            t, self.pending = self.pending, None
            self.notify(t)

    def notify(self, t: dict):
        if not toasts_enabled():
            self.last_reason = "off in config"
            return
        why = quiet_now()
        if why:
            self.last_reason = why
            return
        url = t.get("art") or ""
        if not url.startswith(("http://", "https://", "file:")):
            self.show(t, None)
            return
        path = self.art_dir / (hashlib.sha1(url.encode()).hexdigest()[:20] + ".jpg")
        if path.exists():
            self.show(t, path)
            return
        from PySide6.QtNetwork import QNetworkRequest
        req = QNetworkRequest(QUrl(url))
        req.setTransferTimeout(5000)
        reply = self.net.get(req)

        def done():
            got = None
            if not reply.error().value:
                try:
                    self.art_dir.mkdir(parents=True, exist_ok=True)
                    path.write_bytes(bytes(reply.readAll().data()))
                    got = path
                    self._prune()
                except OSError:
                    pass
            reply.deleteLater()
            if self.key(t) == self.last:   # not already skipped past
                self.show(t, got)
        reply.finished.connect(done)

    def _prune(self, keep: int = 40):
        files = sorted(self.art_dir.glob("*.jpg"), key=lambda f: f.stat().st_mtime, reverse=True)
        for f in files[keep:]:
            try:
                f.unlink()
            except OSError:
                pass

    def show(self, t: dict, art: Path | None):
        title = t.get("title") or ""
        a = t.get("artists") or ""
        artist = ", ".join(a) if isinstance(a, list) else str(a)
        album = t.get("album") or ""
        if self.win:
            try:
                self.win.show(toast_xml(title, artist, album, art))
                self.shown += 1
                self.last_reason = "shown"
                return
            except Exception as e:
                log("toast failed, falling back to the tray:", e)
        if self.tray is not None:
            icon = QIcon(QPixmap(str(art))) if art else QIcon()
            self.tray.showMessage(title, artist, icon if not icon.isNull() else self.tray.icon(), 4000)
            self.shown += 1
            self.last_reason = "shown (tray)"


# ---- jump list ------------------------------------------------------------------

CLSID_DestinationList = "{77F10CF0-3DB5-4966-B520-B7C54FD35ED6}"
IID_ICustomDestinationList = "{6332DEBF-87B5-4670-90C0-5E57B408A49E}"
CLSID_EnumerableObjectCollection = "{2D3468C1-36A7-43B6-AC24-D3F02FD9607A}"
IID_IObjectCollection = "{5632B1A4-E38A-400A-928A-D4CD63230295}"
IID_IObjectArray = "{92CA9DCD-5622-4BBA-A805-5E9F541BD8C9}"
CLSID_ShellLink = "{00021401-0000-0000-C000-000000000046}"
IID_IShellLinkW = "{000214F9-0000-0000-C000-000000000046}"
IID_IPersistFile = "{0000010B-0000-0000-C000-000000000046}"
IID_IPropertyStore = "{886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99}"
PKEY_Title = ("{F29F85E0-4FF9-1068-AB91-08002B27B3D9}", 2)
PKEY_AppUserModel_ID = ("{9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3}", 5)

JUMP_TASKS = [("Play/Pause", "control:toggle", "play"),
              ("Next", "control:next", "next"),
              ("Visualizer", "toggle", "viz"),
              ("Player", "library", None)]


def pythonw() -> str:
    exe = sys.executable
    alt = exe[:-len("python.exe")] + "pythonw.exe" if exe.lower().endswith("python.exe") else exe
    return alt if Path(alt).exists() else exe


def set_prop(store: Com, key, value: str):
    pk = PROPERTYKEY(guid(key[0]), key[1])
    buf = ctypes.create_unicode_buffer(value)
    pv = PROPVARIANT(vt=VT_LPWSTR, p=ctypes.cast(buf, c_void_p).value)
    hr_ok(store(6, (POINTER(PROPERTYKEY), POINTER(PROPVARIANT)), byref(pk), byref(pv)), "IPropertyStore::SetValue")


def get_prop(store: Com, key) -> str:
    pk = PROPERTYKEY(guid(key[0]), key[1])
    pv = PROPVARIANT()
    if store(5, (POINTER(PROPERTYKEY), POINTER(PROPVARIANT)), byref(pk), byref(pv)) < 0:
        return ""
    v = ctypes.wstring_at(pv.p) if pv.vt == VT_LPWSTR and pv.p else ""
    ctypes.windll.ole32.PropVariantClear(byref(pv))
    return v


def shell_link(args: str, title: str, icon: Path | None, cwd: str) -> Com:
    link = create(CLSID_ShellLink, IID_IShellLinkW)
    w = (ctypes.c_wchar_p,)
    hr_ok(link(20, w, pythonw()), "SetPath")
    hr_ok(link(11, w, args), "SetArguments")
    hr_ok(link(9, w, cwd), "SetWorkingDirectory")
    hr_ok(link(7, w, title), "SetDescription")
    if icon and icon.exists():
        hr_ok(link(17, (ctypes.c_wchar_p, c_int), str(icon), 0), "SetIconLocation")
    store = link.qi(IID_IPropertyStore)
    set_prop(store, PKEY_Title, title)
    hr_ok(store(7), "IPropertyStore::Commit")
    return link


def build_jump_list(icon_dir: Path, app_ico: Path | None, cwd: str) -> int:
    icon_dir.mkdir(parents=True, exist_ok=True)
    col = create(CLSID_EnumerableObjectCollection, IID_IObjectCollection)
    links = []
    for title, action, kind in JUMP_TASKS:
        ico = app_ico
        if kind:
            ico = icon_dir / f"{kind}.ico"
            QPixmap.fromImage(glyph(kind, 32, QColor("#5b8cff"))).save(str(ico))
        link = shell_link(f"-m orpheusd.desktop --open {action}", title, ico, cwd)
        hr_ok(col(5, (c_void_p,), link.ptr), "IObjectCollection::AddObject")
        links.append(link)
    dl = create(CLSID_DestinationList, IID_ICustomDestinationList)
    hr_ok(dl(3, (ctypes.c_wchar_p,), AUMID), "SetAppID")
    slots, removed = c_uint(), c_void_p()
    hr_ok(dl(4, (POINTER(c_uint), POINTER(GUID), POINTER(c_void_p)),
             byref(slots), byref(guid(IID_IObjectArray)), byref(removed)), "BeginList")
    Com(removed.value)  # released straight away: tasks cannot be removed by the user
    arr = col.qi(IID_IObjectArray)
    hr_ok(dl(7, (c_void_p,), arr.ptr), "AddUserTasks")
    return hr_ok(dl(8), "CommitList")


def desktop_shortcut() -> Path:
    """The desktop's Orpheus.lnk. Ask the shell for the folder: OneDrive moves it."""
    buf = ctypes.create_unicode_buffer(260)
    ctypes.windll.shell32.SHGetFolderPathW(None, 0x10, None, 0, buf)  # CSIDL_DESKTOPDIRECTORY
    return Path(buf.value) / "Orpheus.lnk"


def tag_shortcut():
    """Stamp the Start-menu and desktop shortcuts with the app's AUMID, so a pinned
    taskbar button, the running window and the jump list all belong to it."""
    for path in (SHORTCUT, desktop_shortcut()):
        if not path.exists():
            continue
        link = create(CLSID_ShellLink, IID_IShellLinkW)
        pf = link.qi(IID_IPersistFile)
        hr_ok(pf(5, (ctypes.c_wchar_p, wintypes.DWORD), str(path), 2), "IPersistFile::Load")  # STGM_READWRITE
        store = link.qi(IID_IPropertyStore)
        if get_prop(store, PKEY_AppUserModel_ID) == AUMID:
            continue
        set_prop(store, PKEY_AppUserModel_ID, AUMID)
        hr_ok(store(7), "IPropertyStore::Commit")
        hr_ok(pf(6, (ctypes.c_wchar_p, wintypes.BOOL), None, True), "IPersistFile::Save")


# ---- wiring ---------------------------------------------------------------------

def set_app_id():
    """Call before any window exists: windows take the process's AUMID when created."""
    if WINDOWS:
        ctypes.windll.shell32.SetCurrentProcessExplicitAppUserModelID(ctypes.c_wchar_p(AUMID))


class Shell(QAbstractNativeEventFilter):
    def __init__(self, fire, tray=None, icon: QPixmap | None = None, jump_list: bool = True):
        super().__init__()
        self.taskbar = Taskbar(fire)
        icon_png = None
        try:
            from orpheusd.system import STATE_DIR
            STATE_DIR.mkdir(parents=True, exist_ok=True)
            if icon is not None:
                icon_png = STATE_DIR / "orpheus-256.png"
                if not icon_png.exists():
                    icon.save(str(icon_png))
        except Exception as e:
            log("icon:", e)
            STATE_DIR = None
        self.toaster = Toaster(tray, icon_png)
        if jump_list:
            try:
                com_init()
                tag_shortcut()
                ico = Path(os.environ.get("LOCALAPPDATA", "")) / "Orpheus" / "orpheus.ico"
                base = STATE_DIR or Path.home()
                build_jump_list(base / "jumplist", ico if ico.exists() else None,
                                str(Path(__file__).resolve().parents[2]))
            except Exception as e:
                log("jump list:", e)

    def nativeEventFilter(self, event_type, message):
        if event_type == b"windows_generic_MSG":
            msg = wintypes.MSG.from_address(int(message))
            try:
                if self.taskbar.on_message(msg):
                    return True, 0
            except Exception as e:
                log("taskbar:", e)
        return False, 0

    def sync(self, p: dict):
        for part in (self.taskbar, self.toaster):
            try:
                part.sync(p)
            except Exception as e:
                log(type(part).__name__, e)


def install(app, fire, tray=None, icon: QPixmap | None = None):
    """Hook it all up; returns the Shell (keep a reference) or None off Windows."""
    if not WINDOWS:
        return None
    try:
        shell = Shell(fire, tray, icon)
        app.installNativeEventFilter(shell)
        from .shims import PLAYER_LISTENERS
        PLAYER_LISTENERS.append(shell.sync)
        return shell
    except Exception as e:   # never worth failing the app over
        log("not installed:", e)
        return None
