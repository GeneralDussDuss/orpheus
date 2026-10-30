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
    # Started from the Start menu there is no console, so the log is the only
    # place a failure can show up.
    from orpheusd.system import STATE_DIR
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    log = open(STATE_DIR / "orpheusd.log", "w", encoding="utf-8")
    return subprocess.Popen([sys.executable, "-m", "orpheusd"], creationflags=flags,
                            stdout=log, stderr=subprocess.STDOUT)


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


def tell_daemon(kind: str, arg: str):
    """A transport or volume hotkey: straight to orpheusd, off the UI thread."""
    base = f"http://127.0.0.1:{PORT}"
    try:
        if kind == "volume":
            with urllib.request.urlopen(base + "/status", timeout=2) as r:
                vol = json.load(r)["player"]["volume"]
            path, body = "/control/volume", {"volume": max(0, min(100, vol + int(arg)))}
        else:
            path, body = f"/control/{arg}", {}
        req = urllib.request.Request(base + path, data=json.dumps(body).encode(),
                                     headers={"Content-Type": "application/json"})
        urllib.request.urlopen(req, timeout=2).close()
    except (OSError, ValueError, KeyError) as e:
        print(f"orpheus-desktop: hotkey {kind}:{arg} failed: {e}", file=sys.stderr)


def fire(action: str):
    kind, _, arg = action.partition(":")
    if not arg:
        call("orpheus", action)
        return
    if kind == "widget":
        call("orpheus", "widget", "enabled", arg)
        return
    if kind == "theme":
        from .shims import THEME
        if THEME:
            THEME[0].cycle(1 if arg == "next" else -1)
        return
    import threading
    threading.Thread(target=tell_daemon, args=(kind, arg), daemon=True).start()


def make_icon(size: int = 256):
    """Orpheus's mark, drawn rather than shipped: the /// of the wordmark in the
    accent blue on the near-black ground, readable down to the 16 px tray."""
    from PySide6.QtCore import QPointF, Qt
    from PySide6.QtGui import QColor, QPainter, QPen, QPixmap
    pm = QPixmap(size, size)
    pm.fill(Qt.GlobalColor.transparent)
    p = QPainter(pm)
    p.setRenderHint(QPainter.RenderHint.Antialiasing)
    p.setPen(Qt.PenStyle.NoPen)
    p.setBrush(QColor("#0b0d12"))
    p.drawRoundedRect(0, 0, size, size, size * 0.22, size * 0.22)
    pen = QPen(QColor("#5b8cff"), size * 0.11, Qt.PenStyle.SolidLine, Qt.PenCapStyle.RoundCap)
    p.setPen(pen)
    for i in range(3):
        x = size * (0.30 + i * 0.20)
        p.drawLine(QPointF(x - size * 0.10, size * 0.74), QPointF(x + size * 0.10, size * 0.26))
    p.end()
    return pm


def theme_menu(parent, key=None):
    """One entry per palette, ticked on the live one. Rebuilt on every open, so a
    hotkey switch or a .toml dropped into ~/.config/orpheus/themes shows up."""
    from PySide6.QtGui import QAction, QActionGroup
    from PySide6.QtWidgets import QMenu
    from .shims import THEME, theme_groups, theme_label
    from .themebuilder import open_builder
    m = QMenu("Theme" + (f"\t{key}" if key else ""), parent)

    def fill():
        m.clear()
        build = QAction("Theme builder…", m)
        build.triggered.connect(open_builder)
        m.addAction(build)
        group = QActionGroup(m)
        current = THEME[0].property("name") if THEME else ""
        for section, names in theme_groups():
            m.addSection(section)
            for name in names:
                a = QAction(theme_label(name), m, checkable=True)
                a.setChecked(name == current)
                a.triggered.connect(lambda _=False, n=name: THEME and THEME[0].set_theme(n))
                group.addAction(a)
                m.addAction(a)
    m.aboutToShow.connect(fill)
    fill()
    return m


def tray(app, quit_all, hotkeys):
    from PySide6.QtGui import QAction, QIcon
    from PySide6.QtWidgets import QMenu, QSystemTrayIcon
    from . import winsys
    t = QSystemTrayIcon(QIcon(make_icon()), app)
    t.setToolTip("Orpheus")
    keys = {m: label for label, _, _, m in winsys.HOTKEYS if label in hotkeys.active}
    menu = QMenu()
    for label, method in (("Player", "library"), ("Visualizer", "toggle"), ("Mini player", "miniPlayer"),
                          ("Show/hide widget", "widget:toggle")):
        a = QAction(label + (f"\t{keys[method]}" if method in keys else ""), menu)
        a.triggered.connect(lambda _=False, m=method: fire(m))
        menu.addAction(a)
    menu.addSeparator()
    menu.addMenu(theme_menu(menu, keys.get("theme:next")))
    from .themebuilder import open_builder
    build = QAction("Theme builder…", menu)
    build.triggered.connect(open_builder)
    menu.addAction(build)
    if winsys.WINDOWS:
        auto = QAction("Start with Windows", menu, checkable=True)
        auto.setChecked(winsys.starts_with_windows())
        auto.toggled.connect(winsys.set_start_with_windows)
        menu.addAction(auto)
    q = QAction("Quit", menu)
    q.triggered.connect(quit_all)
    menu.addAction(q)
    t.setContextMenu(menu)
    t.activated.connect(lambda reason: call("orpheus", "library")
                        if reason == QSystemTrayIcon.ActivationReason.Trigger else None)
    t.show()
    return t, menu


INSTANCE = "orpheus-desktop-" + (os.environ.get("USERNAME") or os.environ.get("USER") or "me")


def hand_over(method: str) -> bool:
    """If Orpheus is already running, ask it to open `method` and say so: a second
    launch from the Start menu should raise the player, not start a second app."""
    from PySide6.QtNetwork import QLocalSocket
    sock = QLocalSocket()
    sock.connectToServer(INSTANCE)
    if not sock.waitForConnected(1500):
        # Not found (Windows says "Invalid name") or refused is the normal first launch.
        quiet = (QLocalSocket.LocalSocketError.ServerNotFoundError,
                 QLocalSocket.LocalSocketError.ConnectionRefusedError)
        if sock.error() not in quiet:
            print(f"orpheus-desktop: cannot reach {INSTANCE}: {sock.errorString()}", file=sys.stderr)
        return False
    sock.write(method.encode() + b"\n")
    sock.waitForBytesWritten(300)
    sock.disconnectFromServer()
    return True


def listen_for_launches(app):
    from PySide6.QtNetwork import QLocalServer
    QLocalServer.removeServer(INSTANCE)  # a crashed run can leave a stale one on Linux
    server = QLocalServer(app)
    if not server.listen(INSTANCE):
        print(f"orpheus-desktop: cannot listen on {INSTANCE}: {server.errorString()}", file=sys.stderr)
    else:
        print(f"orpheus-desktop: listening on {server.fullServerName()}", file=sys.stderr)

    def deliver(method, tries=40):
        # It listens before the QML has loaded, so hold a request until the player can take it.
        from PySide6.QtCore import QTimer
        from .shims import IPC_HANDLERS
        if "orpheus" in IPC_HANDLERS:
            call("orpheus", method)
        elif tries:
            QTimer.singleShot(250, lambda: deliver(method, tries - 1))

    def accept():
        conn = server.nextPendingConnection()
        conn.readyRead.connect(lambda: [deliver(m) for m in
                                        bytes(conn.readAll().data()).decode().split() if m != "none"])
    server.newConnection.connect(accept)
    return server


def main():
    ap = argparse.ArgumentParser(prog="orpheus-desktop")
    ap.add_argument("--shot", metavar="DIR", help="render off-screen, save each window, quit")
    ap.add_argument("--open", default="library", help="IPC method to call once loaded, or 'none'")
    ap.add_argument("--write-icon", metavar="PATH", help="write the app icon (.ico/.png) and quit")
    ap.add_argument("--no-daemon", action="store_true", help="do not start orpheusd")
    ap.add_argument("--style", help="visual style to switch to first (prism is slow to render off-screen)")
    args = ap.parse_args()
    if sys.stderr is None or "pythonw" in Path(sys.executable).name.lower():
        # pythonw has no console: keep this app's own errors too.
        from orpheusd.system import STATE_DIR
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        sys.stdout = sys.stderr = open(STATE_DIR / "desktop.log", "w", encoding="utf-8", buffering=1)

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
    if args.write_icon:
        sys.exit(0 if make_icon().save(args.write_icon) else 1)
    if not args.shot and hand_over(args.open):
        return
    # Listen straight away: a second launch during the few seconds the QML takes
    # to load must still find this one.
    launches = None if args.shot else listen_for_launches(app)
    from PySide6.QtGui import QIcon
    app.setWindowIcon(QIcon(make_icon()))

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
    hotkeys = None
    if args.shot:
        QTimer.singleShot(1500, lambda: (args.style and call("orpheus", "style", args.style),
                                         call("orpheus", args.open)))
        QTimer.singleShot(6000, lambda: (shoot(app, Path(args.shot), engine), app.quit()))
    else:
        from . import winsys
        hotkeys = winsys.Hotkeys(fire)
        app.installNativeEventFilter(hotkeys)
        if hotkeys.failed:
            print("orpheus-desktop: hotkeys taken by another app:", ", ".join(hotkeys.failed), file=sys.stderr)
        keep = (tray(app, quit_all, hotkeys), launches)
        if args.open != "none":
            QTimer.singleShot(800, lambda: call("orpheus", args.open))
    code = app.exec()
    if hotkeys:
        hotkeys.release()
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
