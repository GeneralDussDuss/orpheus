"""orpheus-desktop: the Orpheus player and visualizers as a plain desktop app.

It loads the very QML the Omarchy shell loads (Service.qml and everything it opens),
on top of the stand-ins in shims.py, starts orpheusd if it is not already running,
and sits in the system tray in place of the bar widget.

    orpheus-desktop                 tray + player
    orpheus-desktop --shot DIR      render off-screen, save each window to DIR, quit
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]          # the checkout: Service.qml lives here
HERE = Path(__file__).resolve().parent
PORT = int(os.environ.get("ORPHEUS_PORT", 47837))


def daemon_up() -> bool:
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{PORT}/status", timeout=1) as r:
            return r.status == 200
    except OSError:
        return False


def find_tools():
    """cava's installer and winget only reach PATH in a new shell, so a first run
    straight after installing would not find them. Put their folders on PATH for
    this process and everything it starts."""
    if sys.platform != "win32":
        return
    import glob
    import shutil
    env = os.environ.get
    places = {"cava": [rf"{env('LOCALAPPDATA', '')}\cava\cava.exe",   # winget's default
                       rf"{env('ProgramFiles', '')}\cava\cava.exe",
                       rf"{env('LOCALAPPDATA', '')}\Programs\cava\cava.exe"],
              "yt-dlp": [rf"{env('LOCALAPPDATA', '')}\Microsoft\WinGet\Links\yt-dlp.exe",
                         rf"{env('LOCALAPPDATA', '')}\Microsoft\WinGet\Packages\*yt-dlp*\**\yt-dlp.exe"]}
    for tool, patterns in places.items():
        if shutil.which(tool):
            continue
        for pattern in patterns:
            hits = glob.glob(pattern, recursive=True)
            if hits:
                os.environ["PATH"] = str(Path(hits[0]).parent) + os.pathsep + os.environ["PATH"]
                break


def start_daemon():
    """Without systemd, the app owns the daemon: started here, stopped on quit."""
    if daemon_up():
        return None
    flags = subprocess.CREATE_NO_WINDOW if sys.platform == "win32" else 0
    return subprocess.Popen([sys.executable, "-m", "orpheusd"], creationflags=flags)


def call(target: str, method: str, *args) -> str:
    """Run one of the plugin's IPC functions, the way `omarchy-shell orpheus` does."""
    from PySide6.QtCore import QMetaObject, Q_ARG, Q_RETURN_ARG, Qt
    from .shims import IPC_HANDLERS
    h = IPC_HANDLERS.get(target)
    if h is None:
        print(f"orpheus-desktop: no IPC target {target!r}", file=sys.stderr)
        return ""
    # The QML functions declare `: string`, so the call needs somewhere to put it.
    return QMetaObject.invokeMethod(h, method, Qt.ConnectionType.DirectConnection,
                                    Q_RETURN_ARG(str), *[Q_ARG(str, str(a)) for a in args]) or ""


def tray(app, quit_all):
    from PySide6.QtGui import QAction, QIcon
    from PySide6.QtWidgets import QMenu, QSystemTrayIcon
    icon = QIcon(str(ROOT / "docs" / "media" / "icon.png")) if (ROOT / "docs/media/icon.png").exists() \
        else app.style().standardIcon(app.style().StandardPixmap.SP_MediaPlay)
    t = QSystemTrayIcon(icon, app)
    t.setToolTip("Orpheus")
    menu = QMenu()
    for label, method in (("Player", "library"), ("Visualizer", "toggle"), ("Mini player", "miniPlayer")):
        a = QAction(label, menu)
        a.triggered.connect(lambda _=False, m=method: call("orpheus", m))
        menu.addAction(a)
    menu.addSeparator()
    q = QAction("Quit", menu)
    q.triggered.connect(quit_all)
    menu.addAction(q)
    t.setContextMenu(menu)
    t.activated.connect(lambda reason: call("orpheus", "library")
                        if reason == QSystemTrayIcon.ActivationReason.Trigger else None)
    t.show()
    return t, menu


def main():
    ap = argparse.ArgumentParser(prog="orpheus-desktop")
    ap.add_argument("--shot", metavar="DIR", help="render off-screen, save each window, quit")
    ap.add_argument("--open", default="library", help="IPC method to call once loaded")
    ap.add_argument("--no-daemon", action="store_true", help="do not start orpheusd")
    ap.add_argument("--style", help="visual style to switch to first (prism is slow to render off-screen)")
    args = ap.parse_args()

    qt_argv = sys.argv[:1] + (["-platform", "offscreen"] if args.shot else [])
    if args.shot and "ORPHEUS_HOME" not in os.environ:
        import tempfile
        os.environ["ORPHEUS_HOME"] = tempfile.mkdtemp(prefix="orpheus-shot-")
    from PySide6.QtCore import QTimer, QUrl
    from PySide6.QtQml import QQmlApplicationEngine, qmlRegisterType
    from PySide6.QtWidgets import QApplication

    app = QApplication(qt_argv)
    app.setApplicationName("Orpheus")
    app.setQuitOnLastWindowClosed(False)

    from . import shims  # noqa: F401  registers the stand-in modules
    qmlRegisterType(QUrl.fromLocalFile(str(HERE / "qml" / "PanelEdges.qml")), "OrpheusDesktop", 1, 0, "PanelEdges")
    for name in ("PanelWindow", "FloatingWindow"):
        qmlRegisterType(QUrl.fromLocalFile(str(HERE / "qml" / f"{name}.qml")), "Quickshell", 1, 0, name)

    find_tools()
    daemon = None if args.no_daemon else start_daemon()
    engine = QQmlApplicationEngine()
    shims.refresh_screens(engine)
    for sig in (app.screenAdded, app.screenRemoved):
        sig.connect(lambda *_: shims.refresh_screens(engine))
    engine.warnings.connect(lambda ws: [print("qml:", w.toString(), file=sys.stderr) for w in ws])
    engine.load(QUrl.fromLocalFile(str(ROOT / "Service.qml")))
    if not engine.rootObjects():
        print("orpheus-desktop: Service.qml failed to load", file=sys.stderr)
        sys.exit(1)

    def quit_all():
        if daemon:
            daemon.terminate()
        app.quit()

    keep = None
    if args.shot:
        QTimer.singleShot(1500, lambda: (args.style and call("orpheus", "style", args.style),
                                         call("orpheus", args.open)))
        QTimer.singleShot(6000, lambda: (shoot(app, Path(args.shot), engine), app.quit()))
    else:
        keep = tray(app, quit_all)
        QTimer.singleShot(800, lambda: call("orpheus", args.open))
    code = app.exec()
    if daemon:
        daemon.terminate()
    del keep
    sys.exit(code)


def shoot(app, out: Path, engine=None):
    from PySide6.QtQuick import QQuickWindow
    from shiboken6 import Shiboken
    out.mkdir(parents=True, exist_ok=True)
    shots = []
    for i, w in enumerate(app.topLevelWindows()):
        if not w.isVisible():
            continue
        # PySide hands QML windows back as plain QWindow and caches that wrapper,
        # so drop it and wrap the same object again as the QQuickWindow it is.
        ptr = Shiboken.getCppPointer(w)[0]
        Shiboken.invalidate(w)
        w = Shiboken.wrapInstance(ptr, QQuickWindow)
        name = f"{i}-{(w.title() or w.metaObject().className()).replace(' ', '_')[:30]}.png"
        w.grabWindow().save(str(out / name))
        shots.append({"file": name, "w": w.width(), "h": w.height()})
    print(json.dumps(shots))

if __name__ == "__main__":
    main()
