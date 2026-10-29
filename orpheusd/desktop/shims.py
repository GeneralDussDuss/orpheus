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
        os.replace(tmp, path)
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


@QmlElement
@QmlSingleton
class Mpris(QObject):
    """Other players' state; Windows has no MPRIS, so there are none."""
    changed = Signal()
    players = Property("QVariant", lambda self: None, notify=changed)


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


@QmlElement
@QmlSingleton
class Color(QObject):
    """The theme. Omarchy's comes from the shell; here it is Orpheus's own dark one
    with the system accent, so the contrast guards in the QML still have work to do."""
    changed = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        bg = QColor("#0b0d12")
        bg.setAlphaF(0.94)
        self._v = {"background": bg, "foreground": QColor("#d7dbe6"), "accent": _accent(),
                   "urgent": QColor("#ff5c7a")}

    background = Property(QColor, _getter("background"), notify=changed)
    foreground = Property(QColor, _getter("foreground"), notify=changed)
    accent = Property(QColor, _getter("accent"), notify=changed)
    urgent = Property(QColor, _getter("urgent"), notify=changed)
    shellValues = Property("QVariant", lambda self: {}, notify=changed)

    @Slot(str, str, result=QColor)
    def flatColor(self, spec, fallback):
        c = QColor(spec)
        return c if c.isValid() else QColor(fallback)


class _Font(QObject):
    changed = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self._family = "Cascadia Mono" if sys.platform == "win32" else "monospace"

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
