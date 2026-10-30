"""Stand-ins for the parts of Quickshell and the Omarchy shell that Orpheus's QML uses.

The Omarchy shell is Linux-only, but the plugin only leans on a small surface of it:
running processes, reading and watching files, a handful of singletons, layer-shell
windows and the theme. This module provides that surface on plain Qt, so the very
same QML runs as a desktop app (on Windows, and on Linux for testing).

Each class is registered under the import name the QML already uses. Anything with
no meaning off Hyprland (layers, exclusion zones, toplevels) is accepted and ignored.
"""
from __future__ import annotations

import os
import shutil
import sys
import time
from pathlib import Path

from PySide6.QtCore import (Property, QFileSystemWatcher, QObject, QProcess, QSize,
                            QTimer, Signal, Slot, QEnum)
from PySide6.QtGui import QColor, QGuiApplication
from PySide6.QtQml import QJSValue, QmlAttached, QmlElement, QmlSingleton, QmlUncreatable

from enum import IntEnum

QML_IMPORT_MAJOR_VERSION = 1

# ---- Quickshell.Io -------------------------------------------------------------

QML_IMPORT_NAME = "Quickshell.Io"


@QmlElement
class StdioCollector(QObject):
    """Collects all of a process's output; `text` is set when the stream ends."""
    streamFinished = Signal()
    textChanged = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self._buf = ""
        self._text = ""

    def feed(self, chunk: str):
        self._buf += chunk

    def finish(self):
        self._text, self._buf = self._buf, ""
        self.textChanged.emit()
        self.streamFinished.emit()

    text = Property(str, lambda self: self._text, notify=textChanged)


@QmlElement
class SplitParser(QObject):
    """Hands a process's output over one chunk at a time, split on `splitMarker`."""
    read = Signal(str, arguments=["data"])
    splitMarkerChanged = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self._marker = "\n"
        self._buf = ""

    def feed(self, chunk: str):
        self._buf += chunk
        while self._marker and self._marker in self._buf:
            line, self._buf = self._buf.split(self._marker, 1)
            self.read.emit(line.rstrip("\r"))

    def finish(self):
        if self._buf:
            self.read.emit(self._buf.rstrip("\r"))
        self._buf = ""

    def _set_marker(self, m):
        self._marker = m
        self.splitMarkerChanged.emit()

    splitMarker = Property(str, lambda self: self._marker, _set_marker, notify=splitMarkerChanged)


_PROCESSES: "weakref.WeakSet[Process]" = None    # every live Process, for stop_processes()


def stop_processes():
    """End every child the QML started (cava, audiocap): the app is quitting."""
    for p in list(_PROCESSES or ()):
        try:
            p._set_running(False)
        except RuntimeError:        # its C++ side is already gone
            pass


@QmlElement
class Process(QObject):
    """A child process: set `command`, flip `running` on, get `exited(code)` back."""
    exited = Signal(int, int, arguments=["exitCode", "exitStatus"])
    started = Signal()
    commandChanged = Signal()
    runningChanged = Signal()
    stdoutChanged = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self._command: list = []
        self._stdout = None
        self._proc: QProcess | None = None
        global _PROCESSES
        if _PROCESSES is None:
            import weakref
            _PROCESSES = weakref.WeakSet()
        _PROCESSES.add(self)

    def _set_command(self, cmd):
        self._command = [str(c) for c in (cmd or [])]
        self.commandChanged.emit()

    def _running(self) -> bool:
        return self._proc is not None

    def _set_running(self, on: bool):
        if on and not self._proc:
            self._start()
        elif not on and self._proc:
            p, self._proc = self._proc, None
            p.finished.disconnect()
            p.kill()
            p.waitForFinished(500)
            self.runningChanged.emit()

    def _start(self):
        if not self._command:
            return
        p = QProcess(self)
        p.setProcessChannelMode(QProcess.ProcessChannelMode.SeparateChannels)
        p.readyReadStandardOutput.connect(self._on_output)
        p.finished.connect(self._on_finished)
        p.errorOccurred.connect(self._on_error)
        self._proc = p
        self.runningChanged.emit()
        p.start(self._command[0], self._command[1:])
        if p.processId():            # Windows creates it inside start()
            from .winsys import own_child
            own_child(int(p.processId()))   # cava/audiocap end with the app, even on a crash

    def _on_output(self):
        if self._proc and self._stdout is not None:
            data = bytes(self._proc.readAllStandardOutput().data()).decode("utf-8", "replace")
            self._stdout.feed(data)

    def _on_error(self, err):
        # A command that is not installed never starts and so never finishes.
        if err == QProcess.ProcessError.FailedToStart and self._proc:
            self._proc = None
            self.runningChanged.emit()
            if self._stdout is not None:
                self._stdout.finish()
            self.exited.emit(127, 1)

    def _on_finished(self, code, status):
        if self._proc is None:
            return
        self._on_output()
        self._proc = None
        if self._stdout is not None:
            self._stdout.finish()
        self.runningChanged.emit()
        self.exited.emit(code, int(status.value) if hasattr(status, "value") else int(status))

    def _set_stdout(self, obj):
        self._stdout = obj
        self.stdoutChanged.emit()

    command = Property("QVariantList", lambda self: self._command, _set_command, notify=commandChanged)
    running = Property(bool, _running, _set_running, notify=runningChanged)
    stdout = Property(QObject, lambda self: self._stdout, _set_stdout, notify=stdoutChanged)


@QmlElement
class FileView(QObject):
    """A file read on demand and, with `watchChanges`, re-announced when it changes."""
    loaded = Signal()
    loadFailed = Signal(int, arguments=["error"])
    fileChanged = Signal()
    pathChanged = Signal()
    flagsChanged = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self._path = ""
        self._text = None
        self._watch = False
        self._print = True
        self._watcher = QFileSystemWatcher(self)
        self._watcher.fileChanged.connect(self._on_changed)

    def _set_path(self, p):
        p = str(p or "")
        if p.startswith("file://"):
            p = p[7:]
        self._path = p
        self.pathChanged.emit()
        self._rewatch()
        QTimer.singleShot(0, self.reload)

    def _rewatch(self):
        if self._watcher.files():
            self._watcher.removePaths(self._watcher.files())
        if self._watch and self._path and os.path.exists(self._path):
            self._watcher.addPath(self._path)

    def _on_changed(self, _):
        self._rewatch()  # editors replace files; the watch goes with the old inode
        self.fileChanged.emit()

    @Slot()
    def reload(self):
        try:
            self._text = Path(self._path).read_text(encoding="utf-8")
        except OSError:
            self._text = None
            self.loadFailed.emit(1)
            return
        self.loaded.emit()

    @Slot(result=str)
    def text(self):
        if self._text is None and self._path and os.path.exists(self._path):
            self._text = Path(self._path).read_text(encoding="utf-8")
        return self._text or ""

    @Slot(str)
    def setText(self, text):
        path = Path(self._path)
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(path.suffix + ".tmp")
        tmp.write_text(text, encoding="utf-8")
        # On Windows a watched file is held open, and replacing it is refused; a
        # virus scan of the new file can hold it for a moment too. Unwatch, retry.
        if self._watcher.files():
            self._watcher.removePaths(self._watcher.files())
        for attempt in range(10):
            try:
                os.replace(tmp, path)
                break
            except PermissionError:
                if attempt == 9:
                    raise
                time.sleep(0.05)
        self._text = text
        self._rewatch()

    def _set_watch(self, on):
        self._watch = bool(on)
        self.flagsChanged.emit()
        self._rewatch()

    def _set_print(self, on):
        self._print = bool(on)
        self.flagsChanged.emit()

    path = Property(str, lambda self: self._path, _set_path, notify=pathChanged)
    watchChanges = Property(bool, lambda self: self._watch, _set_watch, notify=flagsChanged)
    printErrors = Property(bool, lambda self: self._print, _set_print, notify=flagsChanged)


IPC_HANDLERS: dict[str, QObject] = {}

# Windows take Qt Quick's screen objects, not QScreen, so the list comes from QML.
# It is evaluated by the host, never from inside a binding: calling back into the
# engine while it is evaluating one hangs it.
SCREENS: list = [QJSValue()]


def refresh_screens(engine):
    from PySide6.QtQml import QQmlComponent
    c = QQmlComponent(engine)
    c.setData(b"import QtQuick\nQtObject { property var s: Qt.application.screens }", "")
    holder = c.create()
    # Read through the engine: as a Python object the list would not survive the trip.
    SCREENS[0] = engine.toScriptValue(holder).property("s") if holder else QJSValue()
    SCREENS.append(holder)  # keep it alive: the list belongs to it
    del SCREENS[1:-1]


@QmlElement
class IpcHandler(QObject):
    """Registers its functions under `target`; the host's tray and hotkeys call them."""
    targetChanged = Signal()
    enabledChanged = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self._target = ""
        self._enabled = True

    def _set_target(self, t):
        if IPC_HANDLERS.get(self._target) is self:
            del IPC_HANDLERS[self._target]
        self._target = t
        IPC_HANDLERS[t] = self
        self.targetChanged.emit()

    def _set_enabled(self, on):
        self._enabled = bool(on)
        self.enabledChanged.emit()

    target = Property(str, lambda self: self._target, _set_target, notify=targetChanged)
    enabled = Property(bool, lambda self: self._enabled, _set_enabled, notify=enabledChanged)


# ---- Quickshell ----------------------------------------------------------------

QML_IMPORT_NAME = "Quickshell"


@QmlElement
@QmlSingleton
class Quickshell(QObject):
    clipboardTextChanged = Signal()
    screensChanged = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        app = QGuiApplication.instance()
        app.clipboard().dataChanged.connect(self.clipboardTextChanged)
        app.screenAdded.connect(lambda _: QTimer.singleShot(0, self.screensChanged.emit))
        app.screenRemoved.connect(lambda _: QTimer.singleShot(0, self.screensChanged.emit))

    @Slot(str, result=str)
    def env(self, name):
        if name == "HOME":
            # ORPHEUS_HOME keeps a test run off the real ~/.config/orpheus, which the
            # Omarchy plugin on the same machine is watching.
            return os.environ.get("ORPHEUS_HOME") or os.environ.get("HOME") or str(Path.home())
        return os.environ.get(name, "")

    @Slot("QVariantList")
    def execDetached(self, cmd):
        cmd = [str(c) for c in cmd]
        if cmd and shutil.which(cmd[0]):
            QProcess.startDetached(cmd[0], cmd[1:])

    def _clip(self):
        return QGuiApplication.clipboard().text()

    def _set_clip(self, t):
        QGuiApplication.clipboard().setText(t)

    def _screens(self):
        return SCREENS[0]

    clipboardText = Property(str, _clip, _set_clip, notify=clipboardTextChanged)
    screens = Property(QJSValue, _screens, notify=screensChanged)


@QmlElement
class Region(QObject):
    """An input mask. Plain windows take input everywhere, so it is accepted and kept."""
    itemChanged = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self._item = None

    def _set_item(self, i):
        self._item = i
        self.itemChanged.emit()

    item = Property(QObject, lambda self: self._item, _set_item, notify=itemChanged)


@QmlElement
@QmlUncreatable("an enum")
class ExclusionMode(QObject):
    class Mode(IntEnum):
        Normal = 0
        Ignore = 1
        Auto = 2
    QEnum(Mode)


# ---- Quickshell.Wayland ----------------------------------------------------------

QML_IMPORT_NAME = "Quickshell.Wayland"


@QmlElement
@QmlUncreatable("an enum")
class WlrLayer(QObject):
    class Layer(IntEnum):
        Background = 0
        Bottom = 1
        Top = 2
        Overlay = 3
    QEnum(Layer)


@QmlElement
@QmlUncreatable("an enum")
class WlrKeyboardFocus(QObject):
    # `None` is QML's name for it and a keyword in Python, hence the functional form.
    Focus = IntEnum("Focus", [("None", 0), ("Exclusive", 1), ("OnDemand", 2)])
    QEnum(Focus)


def _setter(name):
    def setter(self, v):
        setattr(self, name, v)
        self.changed.emit()
    return setter


def _getter(key):
    return lambda self: self._v[key]


class LayerProps(QObject):
    changed = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self._layer, self._ns, self._focus = 2, "", 0

    layer = Property(int, lambda self: self._layer, _setter("_layer"), notify=changed)
    namespace = Property(str, lambda self: self._ns, _setter("_ns"), notify=changed)
    keyboardFocus = Property(int, lambda self: self._focus, _setter("_focus"), notify=changed)


@QmlElement
@QmlUncreatable("attached only")
@QmlAttached(LayerProps)
class WlrLayershell(QObject):
    @staticmethod
    def qmlAttachedProperties(_, o):
        return LayerProps(o)


# ---- Quickshell.Hyprland ---------------------------------------------------------

QML_IMPORT_NAME = "Quickshell.Hyprland"


def _monitor(screen) -> dict:
    """Hyprland's monitor shape, from a QScreen or a Qt Quick screen object."""
    if screen is None:
        return {}
    if hasattr(screen, "geometry"):
        size, scale = screen.geometry().size(), screen.devicePixelRatio()
        w, h = size.width(), size.height()
    else:
        w, h = screen.property("width") or 0, screen.property("height") or 0
        scale = screen.property("devicePixelRatio") or 1
    return {"name": screen.property("name"), "width": round(w * scale), "height": round(h * scale),
            "scale": scale, "lastIpcObject": {"transform": 0}, "activeWorkspace": None}


@QmlElement
@QmlSingleton
class Hyprland(QObject):
    """No compositor to ask: the focused monitor is the primary screen, and no
    window is ever reported fullscreen."""
    changed = Signal()
    rawEvent = Signal("QVariant", arguments=["event"])  # never fires: no compositor

    @Slot(QObject, result="QVariant")
    def monitorFor(self, screen):
        return _monitor(screen)

    focusedMonitor = Property("QVariant", lambda self: _monitor(QGuiApplication.primaryScreen()), notify=changed)
    toplevels = Property("QVariant", lambda self: {"values": []}, notify=changed)


# ---- Quickshell.Services.Mpris ---------------------------------------------------

QML_IMPORT_NAME = "Quickshell.Services.Mpris"


PLAYER_LISTENERS: list = []   # called with each /status player dict (winshell)
# The daemon as the desktop app last heard it: answering or not, signed in or
# not, and since when (monotonic). The tray and the daemon keeper read it.
STATUS: dict = {"online": False, "login": "", "since": 0.0}


def backoff_ms(fails: int) -> int:
    """How long to wait before asking a daemon that did not answer `fails`
    times in a row: quick at first (a restart takes ~2 s), then every 5 s."""
    return min(5000, 500 * 2 ** max(0, fails - 1))


class OrpheusPlayer(QObject):
    """orpheusd as an MPRIS player. On Linux the daemon publishes itself on the
    bus and the QML finds it there; whether anything is playing, and so whether
    cava runs and the visualizer moves, hangs off it. Here it is fed from /status."""
    changed = Signal()
    positionChanged = Signal()   # the QML calls this to re-read a position that does not tick

    def __init__(self, parent=None):
        super().__init__(parent)
        self._p: dict = {}
        self._at = time.monotonic()

    def update(self, p: dict):
        self._p, self._at = p or {}, time.monotonic()
        if THEME:
            THEME[0].album.track_art(self._track().get("art") or "")
        self.changed.emit()
        self.positionChanged.emit()
        for listener in PLAYER_LISTENERS:
            listener(self._p)

    def _track(self) -> dict:
        return self._p.get("track") or {}

    def _artists(self) -> str:
        a = self._track().get("artists") or ""
        return ", ".join(a) if isinstance(a, list) else str(a)

    def _playing(self) -> bool:
        return bool(self._p.get("playing"))

    def _position(self) -> float:
        pos = float(self._p.get("position") or 0)
        if self._playing():
            pos += time.monotonic() - self._at
        return min(pos, self._length()) if self._length() else pos

    def _length(self) -> float:
        return float(self._p.get("duration") or 0)

    def _seek(self, pos):
        _post("/control/seek",{"position": float(pos)})

    @Slot()
    def togglePlaying(self):
        _post("/control/toggle")

    @Slot()
    def next(self):
        _post("/control/next")

    @Slot()
    def previous(self):
        _post("/control/previous")

    identity = Property(str, lambda self: "Orpheus", constant=True)
    trackTitle = Property(str, lambda self: self._track().get("title") or "", notify=changed)
    trackArtist = Property(str, _artists, notify=changed)
    trackAlbum = Property(str, lambda self: self._track().get("album") or "", notify=changed)
    trackArtUrl = Property(str, lambda self: self._track().get("art") or "", notify=changed)
    isPlaying = Property(bool, _playing, notify=changed)
    position = Property(float, _position, _seek, notify=positionChanged)
    length = Property(float, _length, notify=changed)
    positionSupported = Property(bool, lambda self: True, constant=True)
    lengthSupported = Property(bool, lambda self: True, constant=True)
    canSeek = Property(bool, lambda self: True, constant=True)
    canGoNext = Property(bool, lambda self: True, constant=True)
    canGoPrevious = Property(bool, lambda self: True, constant=True)


_NET = []


def _post(path: str, body: dict | None = None):
    import json
    from PySide6.QtCore import QUrl
    from PySide6.QtNetwork import QNetworkAccessManager, QNetworkRequest
    if not _NET:
        _NET.append(QNetworkAccessManager())
    req = QNetworkRequest(QUrl(f"http://127.0.0.1:{os.environ.get('ORPHEUS_PORT', 47837)}{path}"))
    req.setHeader(QNetworkRequest.KnownHeaders.ContentTypeHeader, "application/json")
    reply = _NET[0].post(req, json.dumps(body or {}).encode())
    reply.finished.connect(reply.deleteLater)


@QmlElement
@QmlSingleton
class Mpris(QObject):
    """Windows has no MPRIS, so the only player is Orpheus's own daemon, followed
    with the same long poll the QML's Api uses (/status?since=<version>): the
    daemon answers when something changes, or after 25 s. That replaced a plain
    poll every second, which cost the daemon and this process a 20 KB status
    each second while paused, hidden or in a game. Positions are interpolated
    by OrpheusPlayer between answers."""
    changed = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        from PySide6.QtNetwork import QNetworkAccessManager
        self._orpheus = OrpheusPlayer(self)
        self._listed = False
        self._net = QNetworkAccessManager(self)
        self._busy = False
        self._version = -1
        self._fails = 0
        self._asked = 0.0
        self._retry = QTimer(self, singleShot=True)
        self._retry.timeout.connect(self._poll)
        QTimer.singleShot(0, self._poll)

    def _poll(self):
        if self._busy:
            return
        from PySide6.QtCore import QUrl
        from PySide6.QtNetwork import QNetworkRequest
        self._busy = True
        self._asked = time.monotonic()
        since = f"?since={self._version}" if STATUS["online"] and self._version >= 0 else ""
        req = QNetworkRequest(QUrl(f"http://127.0.0.1:{os.environ.get('ORPHEUS_PORT', 47837)}/status{since}"))
        req.setTransferTimeout(35000)   # the daemon holds it 25 s at most; a hung one must not wedge us
        reply = self._net.get(req)
        reply.finished.connect(lambda: self._done(reply))

    def _done(self, reply):
        import json
        self._busy = False
        data = None
        if not reply.error().value:
            try:
                data = json.loads(bytes(reply.readAll().data()))
            except ValueError:
                data = None
        reply.deleteLater()
        if isinstance(data, dict):
            self._fails = 0
            changed = data.get("version", -1) != self._version
            self._version = data.get("version", -1)
            was = dict(STATUS)
            STATUS.update(online=True, login=(data.get("login") or {}).get("state", ""), since=time.monotonic())
            p = data.get("player") or {}
            if changed or was != STATUS:
                self._publish(p)
            # Straight back into the long poll, but never faster than 4 a second:
            # a burst of changes (a track loading) is folded, and a daemon that
            # ignores `since` cannot spin this.
            self._retry.start(max(0, int(250 - (time.monotonic() - self._asked) * 1000)))
        else:
            self._fails += 1
            if STATUS["online"] or self._fails == 1:
                STATUS.update(online=False, since=time.monotonic())
                self._publish({})
            self._retry.start(backoff_ms(self._fails))

    def _publish(self, p: dict):
        self._orpheus.update(p)
        listed = bool(p.get("track"))
        if listed != self._listed:
            self._listed = listed
            self.changed.emit()

    players = Property("QVariant", lambda self: {"values": [self._orpheus] if self._listed else []},
                       notify=changed)


# ---- qs.Commons ------------------------------------------------------------------

QML_IMPORT_NAME = "qs.Commons"


def _accent() -> QColor:
    """The Windows accent colour, or Orpheus's own blue."""
    if sys.platform == "win32":
        try:
            import winreg
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Software\Microsoft\Windows\DWM") as k:
                abgr = winreg.QueryValueEx(k, "AccentColor")[0]
            return QColor(abgr & 0xFF, (abgr >> 8) & 0xFF, (abgr >> 16) & 0xFF)
        except OSError:
            pass
    return QColor("#5b8cff")


THEMES_DIR = Path(__file__).resolve().parent / "themes"   # orpheus/ originals, omarchy/ palettes
DEFAULT_THEME = "orpheus"


def user_themes_dir() -> Path:
    home = os.environ.get("ORPHEUS_HOME") or os.environ.get("HOME") or str(Path.home())
    return Path(home) / ".config" / "orpheus" / "themes"


def theme_groups() -> list[tuple[str, list[str]]]:
    """The menu's sections. A user theme with a bundled name replaces it, so it
    is listed once, under Yours."""
    yours = sorted(p.stem for p in user_themes_dir().glob("*.toml")) if user_themes_dir().is_dir() else []
    groups = [("Orpheus", [DEFAULT_THEME, "album"])]
    for label, sub in (("Orpheus", "orpheus"), ("Omarchy", "omarchy")):
        names = sorted(p.stem for p in (THEMES_DIR / sub).glob("*.toml") if p.stem not in yours)
        if label == "Orpheus":
            groups[0][1].extend(n for n in names if n != DEFAULT_THEME)
        elif names:
            groups.append((label, names))
    if yours:
        groups.append(("Yours", yours))
    return groups


def theme_names() -> list[str]:
    return [n for _, names in theme_groups() for n in names]


def theme_label(name: str) -> str:
    return "From Album Art" if name == "album" else name.replace("-", " ").title()


def _theme_file(name: str) -> Path | None:
    for d in (user_themes_dir(), THEMES_DIR / "orpheus", THEMES_DIR / "omarchy"):
        if (d / f"{name}.toml").is_file():
            return d / f"{name}.toml"
    return None


def _read_toml(path: Path) -> dict:
    import tomllib
    with open(path, "rb") as f:
        return {k: v for k, v in tomllib.load(f).items() if isinstance(v, str)}


def _prefs_path() -> Path:
    from orpheusd.system import STATE_DIR
    return STATE_DIR / "desktop.json"


def saved_theme() -> str:
    import json
    try:
        name = json.loads(_prefs_path().read_text(encoding="utf-8")).get("theme", DEFAULT_THEME)
    except (OSError, ValueError, AttributeError):
        return DEFAULT_THEME
    return name if name in theme_names() else DEFAULT_THEME


THEME: list = []   # the live Color singleton, once the QML has made it


@QmlElement
@QmlSingleton
class Color(QObject):
    """The theme. Omarchy's comes from the shell; here there is no desktop theme
    to follow, so the app carries Omarchy's palettes and switches between them
    itself. "orpheus" is the app's own dark look with the system accent."""
    changed = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self._name = ""
        self._v = {}
        THEME[:] = [self]
        from .albumtheme import AlbumTheme
        self.album = AlbumTheme(self, self)
        self.set_theme(saved_theme(), save=False)

    def set_theme(self, name: str, save: bool = True):
        import json
        from .themegen import to_toml
        if name == "album":
            # Until the first cover arrives, keep looking like Orpheus.
            self._name = name
            p = self.album.palette
            self._apply(p or {}, to_toml(p) if p else "")
        else:
            path = _theme_file(name) if name != DEFAULT_THEME else None
            t = _read_toml(path) if path else {}
            if not t:
                name = DEFAULT_THEME
            self._name = name
            self._apply(t, path.read_text(encoding="utf-8") if path else "")
        if save:
            p = _prefs_path()
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(json.dumps({"theme": name}) + "\n", encoding="utf-8")

    def apply_album(self, palette: dict):
        from .themegen import to_toml
        self._apply(palette, to_toml(palette))

    # ---- for QML (the settings page) ----------------------------------------
    themesChanged = Signal()

    def _theme_list(self):
        return [{"name": n, "label": theme_label(n), "group": g} for g, names in theme_groups() for n in names]

    themeList = Property("QVariantList", _theme_list, notify=themesChanged)

    @Slot(str)
    def setTheme(self, name):
        self.set_theme(name)

    @Slot()
    def openBuilder(self):
        from .themebuilder import open_builder
        open_builder()

    @Slot()
    def rescanThemes(self):
        self.themesChanged.emit()

    def preview(self, palette: dict):
        """Show a palette without making it the theme: the builder's live view.
        set_theme(name) afterwards puts the chosen one back."""
        from .themegen import to_toml
        self._apply(palette, to_toml(palette))

    def _apply(self, t: dict, toml_text: str):
        bg = QColor(t.get("background", "#0b0d12"))
        # Omarchy's background is slightly see-through over a blurring compositor.
        # Windows has no blur behind, and a window whose colour has any alpha is
        # made layered, which Windows hit-tests as clear: clicks would fall through.
        bg.setAlphaF(1.0 if sys.platform == "win32" else 0.94)
        self._v = {"background": bg,
                   "foreground": QColor(t.get("foreground", "#d7dbe6")),
                   "accent": QColor(t["accent"]) if "accent" in t else _accent(),
                   "urgent": QColor(t.get("red", "#ff5c7a"))}
        self._write_palette(toml_text)
        self.changed.emit()

    def _write_palette(self, text: str):
        """Service.qml fills its second and third visualizer colours from the
        Omarchy theme's colors.toml. Off Omarchy nothing else owns that file, so
        put the chosen palette there; its file watch picks the change up live."""
        if sys.platform != "win32":
            return  # on Linux that path is the real Omarchy theme
        home = os.environ.get("ORPHEUS_HOME") or os.environ.get("HOME") or str(Path.home())
        dest = Path(home) / ".local" / "state" / "omarchy" / "current" / "theme" / "colors.toml"
        dest.parent.mkdir(parents=True, exist_ok=True)
        try:
            if not dest.exists() or dest.read_text(encoding="utf-8") != text:
                dest.write_text(text, encoding="utf-8")
        except OSError as e:
            print(f"orpheus-desktop: cannot write {dest}: {e}", file=sys.stderr)

    def current_palette(self) -> dict:
        path = _theme_file(self._name) if self._name != DEFAULT_THEME else None
        return _read_toml(path) if path else {
            "background": "#0b0d12", "foreground": "#d7dbe6", "accent": _accent().name()}

    @Slot(int)
    def cycle(self, step=1):
        names = theme_names()
        i = names.index(self._name) if self._name in names else 0
        self.set_theme(names[(i + step) % len(names)])

    name = Property(str, lambda self: self._name, notify=changed)

    background = Property(QColor, _getter("background"), notify=changed)
    foreground = Property(QColor, _getter("foreground"), notify=changed)
    accent = Property(QColor, _getter("accent"), notify=changed)
    urgent = Property(QColor, _getter("urgent"), notify=changed)
    shellValues = Property("QVariant", lambda self: {}, notify=changed)

    @Slot(str, str, result=QColor)
    def flatColor(self, spec, fallback):
        c = QColor(spec)
        return c if c.isValid() else QColor(fallback)


def _mono_family() -> str:
    """The first monospace font that is installed. The TUI lines up only in a
    monospace face, and Qt quietly substitutes a proportional one for a missing name.
    Nerd Fonts go first: the transport and like buttons are Nerd Font glyphs, blank
    in anything else. Windows installs register JetBrains Mono's as "JetBrainsMono NF"."""
    from PySide6.QtGui import QFontDatabase
    have = set(QFontDatabase.families())
    for f in ("JetBrainsMono Nerd Font", "JetBrainsMono NF", "JetBrainsMono Nerd Font Mono",
              "CaskaydiaCove Nerd Font", "CaskaydiaCove NF",
              "Cascadia Mono", "Cascadia Code", "JetBrains Mono",
              "Consolas", "DejaVu Sans Mono", "Liberation Mono", "Courier New"):
        if f in have:
            return f
    return QFontDatabase.systemFont(QFontDatabase.SystemFont.FixedFont).family()


class _Font(QObject):
    changed = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self._family = _mono_family()

    family = Property(str, lambda self: self._family, notify=changed)
    body = Property(int, lambda self: 13, notify=changed)
    caption = Property(int, lambda self: 11, notify=changed)


class _Bar(QObject):
    changed = Signal()
    sizeHorizontal = Property(int, lambda self: 32, notify=changed)


@QmlElement
@QmlSingleton
class Style(QObject):
    changed = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self._font, self._bar = _Font(self), _Bar(self)

    font = Property(QObject, lambda self: self._font, constant=True)
    bar = Property(QObject, lambda self: self._bar, constant=True)
    space = Property(int, lambda self: 8, notify=changed)
    gapsOut = Property(int, lambda self: 10, notify=changed)


# ---- qs.Commons: global hotkeys, for the settings page and the cheat sheet --------

QML_IMPORT_NAME = "qs.Commons"

HOTKEYS_LIVE: list = []        # the winsys.Hotkeys of this run, once __main__ has made it
_HOTKEY_CONFIG: list = [None]  # config.json's `hotkeys`, as Service.qml last pushed it
_KEYS: list = []               # the OrpheusKeys singleton(s), to tell about a rebind


def attach_hotkeys(hk):
    """Hand the live hotkeys to the QML. Service.qml may have pushed the config's
    overrides before they existed; apply those now."""
    HOTKEYS_LIVE[:] = [hk]
    hk.listeners.append(lambda: [k.changed.emit() for k in _KEYS])
    if _HOTKEY_CONFIG[0] is not None:
        hk.register(_HOTKEY_CONFIG[0])
    for k in _KEYS:
        k.changed.emit()


@QmlElement
@QmlSingleton
class OrpheusKeys(QObject):
    """What the global hotkeys are, which combo each one got and why the others
    did not. Desktop only: QML checks `typeof OrpheusKeys` before using it."""
    changed = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        _KEYS.append(self)

    def _bindings(self):
        if HOTKEYS_LIVE:
            return HOTKEYS_LIVE[0].status
        from . import winsys
        why = "not registered in this run"
        return [{"action": a, "label": winsys.ACTION_LABELS.get(a, a), "combo": "", "state": "off",
                 "tried": [{"combo": c, "source": s, "ok": False, "reason": why} for c, s in combos]}
                for a, combos in winsys.plan(_HOTKEY_CONFIG[0])]

    bindings = Property("QVariantList", _bindings, notify=changed)
    live = Property(bool, lambda self: bool(HOTKEYS_LIVE), notify=changed)

    @Slot("QVariant")
    def apply(self, overrides):
        if isinstance(overrides, QJSValue):
            overrides = overrides.toVariant()
        _HOTKEY_CONFIG[0] = dict(overrides) if isinstance(overrides, dict) else {}
        if HOTKEYS_LIVE:
            if HOTKEYS_LIVE[0].overrides != _HOTKEY_CONFIG[0]:
                HOTKEYS_LIVE[0].register(_HOTKEY_CONFIG[0])   # its listener emits changed
        else:
            self.changed.emit()

    @Slot(str, result=str)
    def check(self, combo):
        """"" if `combo` can be a hotkey, else what is wrong with it."""
        from . import winsys
        try:
            winsys.parse_combo(combo)
            return ""
        except ValueError as e:
            return str(e)

    @Slot(str, result=str)
    def normalize(self, combo):
        from . import winsys
        try:
            return winsys.normalize(combo)
        except ValueError:
            return combo

    def _starts(self):
        from . import winsys
        return winsys.starts_with_windows()

    @Slot(bool)
    def setStartWithWindows(self, on):
        from . import winsys
        winsys.set_start_with_windows(bool(on))
        self.changed.emit()

    windows = Property(bool, lambda self: sys.platform == "win32", constant=True)
    startWithWindows = Property(bool, _starts, notify=changed)


# ---- qs.Commons: game mode, the in-game HUD and Discord, for the QML -------------

QML_IMPORT_NAME = "qs.Commons"

_GAME: list = []               # the OrpheusGame singleton(s), to tell about a change


def game_changed(*_):
    for g in _GAME:
        g.changed.emit()


@QmlElement
@QmlSingleton
class OrpheusGame(QObject):
    """Whether a fullscreen game has the screen (gamemode.py), so the widget and
    the stage step back, plus the HUD and Discord's state for the settings page.
    Desktop only: QML checks `typeof OrpheusGame` before using it."""
    changed = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        _GAME.append(self)
        self._discord = ""
        t = QTimer(self)                       # Discord's state changes on its own thread
        t.timeout.connect(self._check_discord)
        t.start(3000)

    def _check_discord(self):
        s = self._discord_state()
        if s != self._discord:
            self._discord = s
            self.changed.emit()

    def _active(self):
        from . import gamemode
        return gamemode.active()

    def _reason(self):
        from . import gamemode
        if not gamemode.DETECTOR:
            return "not running"
        d = gamemode.DETECTOR[0]
        v = d.verdict
        if not d.active:
            return "off in config" if v.reason == "off in config" else "no game in front"
        name = v.exe or v.title
        return v.reason + (f" · {name}" if name else "")

    def _discord_state(self):
        from . import discord
        if not discord.client_id():
            return "off · set discordClientId in config.json"
        if not discord.PRESENCE:
            return "not running"
        p = discord.PRESENCE[0]
        if p.pipe:
            return "connected"
        return "waiting for Discord" + (f" · {p.last_error}" if p.last_error else "")

    gameMode = Property(bool, _active, notify=changed)
    reason = Property(str, _reason, notify=changed)
    discord = Property(str, lambda self: self._discord or self._discord_state(), notify=changed)

    @Slot()
    def showHud(self):
        from . import hud
        hud.show_now()
