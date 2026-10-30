"""orpheus-desktop: the Orpheus player and visualizers as a plain desktop app.

It loads the very QML the Omarchy shell loads (Service.qml and everything it opens),
on top of the stand-ins in shims.py, starts orpheusd if it is not already running,
and sits in the system tray in place of the bar widget.

    orpheus-desktop                 tray + player
    orpheus-desktop --shot DIR      render off-screen, save each window to DIR, quit

ORPHEUS_PORT picks another daemon (and so another instance of this app);
ORPHEUS_ISOLATED=1 is for tests: nothing machine-wide (hotkeys, the jump
list, toasts, Discord, the HUD, the Run key) is touched.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

T0 = time.perf_counter()
ROOT = Path(__file__).resolve().parents[2]          # the checkout: Service.qml lives here
HERE = Path(__file__).resolve().parent
DEFAULT_PORT = 47837
PORT = int(os.environ.get("ORPHEUS_PORT", DEFAULT_PORT))
ISOLATED = os.environ.get("ORPHEUS_ISOLATED") == "1"
WINDOWS = sys.platform == "win32"


def say(*a):
    print("orpheus-desktop:", *a, file=sys.stderr, flush=True)


def since_start() -> str:
    return f"{(time.perf_counter() - T0) * 1000:.0f} ms"


def port_free() -> bool:
    """Nothing is listening on the daemon's port. Instant, unlike asking it:
    on Windows a refused connection to 127.0.0.1 is retried for about a
    second, and that second came straight off every cold start."""
    import socket
    s = socket.socket()
    try:
        if WINDOWS:
            s.setsockopt(socket.SOL_SOCKET, getattr(socket, "SO_EXCLUSIVEADDRUSE", -5), 1)
        s.bind(("127.0.0.1", PORT))
        return True
    except OSError:
        return False
    finally:
        s.close()


def daemon_up(timeout: float = 1) -> bool:
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{PORT}/status", timeout=timeout) as r:
            return r.status == 200
    except OSError:
        return False


def find_tools():
    """cava's installer and winget only reach PATH in a new shell, so a first run
    straight after installing would not find them. Put their folders on PATH for
    this process and everything it starts."""
    if not WINDOWS:
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


# ---- the daemon -------------------------------------------------------------------

def start_daemon(probe: bool = True):
    """Without systemd, the app owns the daemon: started here, stopped on quit,
    and in this app's kill-on-close job, so it cannot outlive a crash of it.
    `probe`: first check for one already running (the keeper knows there is none)."""
    if probe and not port_free() and daemon_up(2):
        return None          # one is running already (left by an earlier run): use it
    from orpheusd.system import STATE_DIR
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    flags = subprocess.CREATE_NO_WINDOW if WINDOWS else 0
    # orpheusd.log is the daemon's own (rotating) log. Its stderr only catches
    # what gets past logging, such as an import error; it is normally empty.
    err = open(STATE_DIR / "orpheusd.stderr.log", "w", encoding="utf-8")
    proc = subprocess.Popen([sys.executable, "-m", "orpheusd", "--log", str(STATE_DIR / "orpheusd.log")],
                            creationflags=flags, stdin=subprocess.DEVNULL, stdout=err, stderr=subprocess.STDOUT)
    err.close()
    from .winsys import own_child
    own_child(proc.pid)
    say(f"started orpheusd (pid {proc.pid}) at {since_start()}")
    return proc


def stop_daemon(proc, adopted_too: bool, wait: float = 5.0):
    """Ask the daemon to quit (it saves the queue and closes the last play),
    then wait for it; TerminateProcess only if it will not go."""
    asked = False
    if proc is not None or adopted_too:
        try:
            req = urllib.request.Request(f"http://127.0.0.1:{PORT}/quit", data=b"{}",
                                         headers={"Content-Type": "application/json"})
            urllib.request.urlopen(req, timeout=1.5).close()
            asked = True
        except OSError:
            pass
    if proc is not None:
        try:
            proc.wait(wait if asked else 0.1)
        except subprocess.TimeoutExpired:
            if asked:
                say("orpheusd would not quit; ending it")
            proc.terminate()
    elif asked:
        end = time.monotonic() + wait
        while time.monotonic() < end and not port_free():
            time.sleep(0.1)
    return asked


def should_restart(ours_alive: bool, ours_died: bool, online: bool, offline_for: float,
                   recent: list[float], now: float, grace: float = 2.5, limit: int = 5,
                   window: float = 120.0) -> bool:
    """The keeper's rule: start a daemon when ours has just died, or when none
    of ours runs and nothing has answered for `grace` seconds (an adopted one
    went away); but never more than `limit` starts in `window` seconds, so a
    daemon that dies at once is not restarted forever."""
    if ours_alive or (online and not ours_died):
        return False
    if not ours_died and offline_for < grace:
        return False
    return sum(1 for t in recent if now - t < window) < limit


class Keeper:
    """Restarts the daemon when it dies (a crash, Task Manager) or when the one
    this app adopted goes away, so the UI's 'reconnecting' ends by itself."""

    def __init__(self, proc, enabled: bool):
        self.proc = proc
        self.enabled = enabled
        self.quitting = False
        self.starts: list[float] = []
        self.gave_up = False

    def check(self):
        from .shims import STATUS
        if self.quitting or not self.enabled:
            return
        alive = self.proc is not None and self.proc.poll() is None
        died = self.proc is not None and not alive
        if died:
            say(f"orpheusd exited with {self.proc.returncode}")
            self.proc = None
        now = time.monotonic()
        offline_for = 0.0 if STATUS["online"] else now - (STATUS["since"] or now)
        if should_restart(alive, died, STATUS["online"], offline_for, self.starts, now):
            self.starts.append(now)
            self.proc = start_daemon(probe=False)
        elif not alive and not STATUS["online"] and offline_for > 2.5 and not self.gave_up \
                and len([t for t in self.starts if now - t < 120]) >= 5:
            self.gave_up = True
            say("orpheusd keeps dying; not restarting it again (see orpheusd.log)")


# ---- IPC to the QML and the daemon ------------------------------------------------

def call(target: str, method: str, *args) -> str:
    """Run one of the plugin's IPC functions, the way `omarchy-shell orpheus` does."""
    from PySide6.QtCore import QMetaObject, Q_ARG, Q_RETURN_ARG, Qt
    from .shims import IPC_HANDLERS
    h = IPC_HANDLERS.get(target)
    if h is None:
        say(f"no IPC target {target!r}")
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
        say(f"hotkey {kind}:{arg} failed: {e}")


def fire(action: str):
    kind, _, arg = action.partition(":")
    if kind in ("control", "volume") and arg:
        import threading
        threading.Thread(target=tell_daemon, args=(kind, arg), daemon=True).start()
        return
    from .shims import IPC_HANDLERS
    if "orpheus" not in IPC_HANDLERS:
        deliver(action)          # the QML is still loading: hold it
        return
    if not arg:
        call("orpheus", action)
    elif kind == "widget":
        call("orpheus", "widget", "enabled", arg)
    elif kind == "hud":
        from . import hud
        hud.show_now()       # the in-game HUD, now; it never takes focus
    elif kind == "theme":
        from .shims import THEME
        if THEME:
            THEME[0].cycle(1 if arg == "next" else -1)


def deliver(method: str, tries: int = 60):
    """An IPC method from the tray, the jump list or a second launch, held until
    the QML has loaded (the tray and the pipe are up before it)."""
    from PySide6.QtCore import QTimer
    from .shims import IPC_HANDLERS
    if "orpheus" in IPC_HANDLERS:
        fire(method)
    elif tries:
        QTimer.singleShot(250, lambda: deliver(method, tries - 1))


# ---- the tray ---------------------------------------------------------------------

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
    m = QMenu("Theme" + (f"\t{key}" if key else ""), parent)

    def fill():
        from .shims import THEME, theme_groups, theme_label
        from .themebuilder import open_builder
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
    return m


def elide(text: str, n: int) -> str:
    return text if len(text) <= n else text[: n - 1].rstrip() + "…"


def now_playing(online: bool, login: str, p: dict, starting: bool = False) -> tuple[str, str]:
    """The tray's top line and its action, from what the daemon last said:
    (label, IPC method to call on a click)."""
    if not online:
        return ("Starting the player service…" if starting else "Reconnecting to the player service…"), "library"
    if login and login != "signed-in":
        return "Sign in to TIDAL…", "login"
    t = p.get("track") or {}
    if not t:
        return "Nothing playing · open the player", "library"
    artists = t.get("artists") or ""
    artists = ", ".join(artists) if isinstance(artists, list) else str(artists)
    mark = "▶" if p.get("playing") else "❚❚"
    line = f"{mark}  {t.get('title') or 'Untitled'}" + (f" — {artists}" if artists else "")
    return elide(line, 60), "library"


class Tray:
    """The tray icon and its menu. Up before the QML loads; the hotkey labels and
    the now-playing line fill in as they become known.

        ▶ Title — Artist          opens the player
        Pause / Next / Previous
        ─ Player · Visualizer · Mini player
        ─ Desktop widget ✓ · Theme ▸
        ─ Settings… · Start with Windows ✓
        ─ Quit Orpheus

    Names follow the settings page: "desktop widget", "start with windows",
    "theme builder…"."""

    def __init__(self, app, quit_all):
        from PySide6.QtGui import QAction, QIcon
        from PySide6.QtWidgets import QMenu, QSystemTrayIcon
        from . import winsys
        self.t = QSystemTrayIcon(QIcon(make_icon()), app)
        self.t.setToolTip("Orpheus")
        self.menu = m = QMenu()
        self.labelled = []      # (action, QAction or QMenu, label): relabelled when hotkeys change
        self.hotkeys = None
        self._open = "library"
        self._p: dict = {}

        def item(label, action, checkable=False):
            a = QAction(label, m, checkable=checkable)
            a.triggered.connect(lambda _=False: fire(action))
            m.addAction(a)
            self.labelled.append((action, a, label))
            return a

        self.np = QAction("Starting the player service…", m)
        f = self.np.font()
        f.setBold(True)
        self.np.setFont(f)
        self.np.triggered.connect(lambda _=False: fire(self._open))
        m.addAction(self.np)
        self.play = item("Play", "control:toggle")
        self.next = item("Next", "control:next")
        self.prev = item("Previous", "control:previous")
        m.addSeparator()
        item("Player", "library")
        item("Visualizer", "toggle")
        item("Mini player", "miniPlayer")
        m.addSeparator()
        self.widget = item("Desktop widget", "widget:toggle", checkable=True)
        themes = theme_menu(m)
        m.addMenu(themes)
        self.labelled.append(("theme:next", themes, "Theme"))
        m.addSeparator()
        item("Settings…", "settings")
        self.auto = None
        if winsys.WINDOWS and not ISOLATED:
            self.auto = QAction("Start with Windows", m, checkable=True)
            self.auto.toggled.connect(winsys.set_start_with_windows)
            m.addAction(self.auto)
        m.addSeparator()
        q = QAction("Quit Orpheus", m)
        q.triggered.connect(quit_all)
        m.addAction(q)
        m.aboutToShow.connect(self._refresh)
        self.t.setContextMenu(m)
        self.t.activated.connect(lambda reason: fire("library")
                                 if reason == QSystemTrayIcon.ActivationReason.Trigger else None)
        self.t.show()
        self.sync({})

    def attach_hotkeys(self, hotkeys):
        self.hotkeys = hotkeys
        self.relabel()
        if hasattr(hotkeys, "listeners"):
            hotkeys.listeners.append(self.relabel)

    def relabel(self):
        from PySide6.QtWidgets import QMenu
        keys = {row["action"]: row["combo"] for row in getattr(self.hotkeys, "status", []) if row.get("combo")}
        for action, item, label in self.labelled:
            if item is self.play:
                label = "Pause" if self._p.get("playing") else "Play"
            text = label + (f"\t{keys[action]}" if action in keys else "")
            (item.setTitle if isinstance(item, QMenu) else item.setText)(text)

    def sync(self, p: dict):
        """A /status player dict (PLAYER_LISTENERS), or {} with the daemon gone."""
        from .shims import STATUS
        self._p = p or {}
        starting = not STATUS["since"] or (time.perf_counter() - T0 < 15 and not STATUS["online"])
        label, self._open = now_playing(STATUS["online"], STATUS["login"], self._p, starting)
        self.np.setText(label)
        has_track = bool(self._p.get("track"))
        for a in (self.play, self.next, self.prev):
            a.setEnabled(STATUS["online"] and has_track)
        self.relabel()
        t = self._p.get("track") or {}
        tip = "Orpheus" + (f" · {t.get('title')}" if t.get("title") else "") \
            + ("" if STATUS["online"] else " · reconnecting")
        self.t.setToolTip(elide(tip, 120))

    def _refresh(self):
        """Ticks that can change behind the menu's back: read them as it opens."""
        from . import winsys
        if self.auto is not None:
            self.auto.blockSignals(True)
            self.auto.setChecked(winsys.starts_with_windows())
            self.auto.blockSignals(False)
        try:
            st = json.loads(call("orpheus", "status") or "{}")
            self.widget.setChecked((st.get("widget") or {}).get("enabled") is not False)
        except (ValueError, AttributeError):
            pass


# ---- single instance ----------------------------------------------------------------

INSTANCE = "orpheus-desktop-" + (os.environ.get("USERNAME") or os.environ.get("USER") or "me") \
    + ("" if PORT == DEFAULT_PORT else f"-{PORT}")     # another daemon, another app


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
            say(f"cannot reach {INSTANCE}: {sock.errorString()}")
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
        say(f"cannot listen on {INSTANCE}: {server.errorString()}")
    else:
        say(f"listening on {server.fullServerName()}")

    def accept():
        conn = server.nextPendingConnection()
        conn.readyRead.connect(lambda: [deliver(m) for m in
                                        bytes(conn.readAll().data()).decode().split() if m != "none"])
    server.newConnection.connect(accept)
    return server


# ---- logging ------------------------------------------------------------------------

def route_qt_messages():
    """qWarning and the QML's console.* go to C stderr, which pythonw does not
    have: they were lost. Send them to desktop.log, repeats folded."""
    from PySide6.QtCore import QtMsgType, qInstallMessageHandler
    from .applog import Repeats
    fold = Repeats()
    names = {QtMsgType.QtDebugMsg: "debug", QtMsgType.QtInfoMsg: "info", QtMsgType.QtWarningMsg: "warning",
             QtMsgType.QtCriticalMsg: "critical", QtMsgType.QtFatalMsg: "fatal"}

    def handler(kind, ctx, msg):
        if kind == QtMsgType.QtDebugMsg and not os.environ.get("ORPHEUS_DEBUG"):
            return            # console.log is for development
        for line in fold.feed(f"qt {names.get(kind, kind)}: {msg}"):
            print(line, file=sys.stderr)
    qInstallMessageHandler(handler)
    return handler


# ---- main ---------------------------------------------------------------------------

QUIT: list = []      # the tray's Quit, for tests


def main():
    ap = argparse.ArgumentParser(prog="orpheus-desktop")
    ap.add_argument("--shot", metavar="DIR", help="render off-screen, save each window, quit")
    ap.add_argument("--open", default="library", help="IPC method to call once loaded, or 'none'")
    ap.add_argument("--write-icon", metavar="PATH", help="write the app icon (.ico/.png) and quit")
    ap.add_argument("--no-daemon", action="store_true", help="do not start orpheusd")
    ap.add_argument("--style", help="visual style to switch to first (prism is slow to render off-screen)")
    args = ap.parse_args()

    qt_argv = sys.argv[:1] + (["-platform", "offscreen"] if args.shot else [])
    if args.shot and "ORPHEUS_HOME" not in os.environ:
        import tempfile
        os.environ["ORPHEUS_HOME"] = tempfile.mkdtemp(prefix="orpheus-shot-")
    from PySide6.QtCore import QTimer, QUrl
    from PySide6.QtWidgets import QApplication

    app = QApplication(qt_argv)
    app.setApplicationName("Orpheus")
    app.setQuitOnLastWindowClosed(False)
    if args.write_icon:
        # A .png at 1024 px: big enough for a Discord Rich Presence art asset.
        size = 1024 if args.write_icon.lower().endswith(".png") else 256
        sys.exit(0 if make_icon(size).save(args.write_icon) else 1)
    if not args.shot and hand_over(args.open):
        return
    if sys.stderr is None or "pythonw" in Path(sys.executable).name.lower():
        # pythonw has no console: keep this app's own errors too. Only the
        # instance that stays opens it: a launch that just handed over to the
        # running one would otherwise wipe that one's log.
        from orpheusd.system import STATE_DIR
        from .applog import CappedLog
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        sys.stdout = sys.stderr = CappedLog(STATE_DIR / "desktop.log")
    route_qt_messages()
    # Listen straight away: a second launch during the second or so the QML
    # takes to load must still find this one.
    launches = None if args.shot else listen_for_launches(app)
    from . import winshell
    if not args.shot and not ISOLATED:
        winshell.set_app_id()   # before any window exists: taskbar, jump list and toasts key on it
    from PySide6.QtGui import QIcon
    app.setWindowIcon(QIcon(make_icon()))

    find_tools()
    if WINDOWS:
        # Service.qml runs the audio capture (audiocap.py) with this interpreter:
        # python.exe rather than pythonw.exe, for a plain stdout pipe.
        exe = Path(sys.executable)
        console = exe.with_name("python.exe")
        os.environ.setdefault("ORPHEUS_PYTHON", str(console if console.exists() else exe))
    # The daemon first: it takes ~2 s to answer, and loads while the QML does.
    daemon = None if args.no_daemon else start_daemon()
    keeper = Keeper(daemon, enabled=not args.no_daemon and not args.shot)

    def quit_all():
        keeper.quitting = True
        if tray_ is not None:
            tray_.t.hide()
        if not args.no_daemon:
            stop_daemon(keeper.proc, adopted_too=WINDOWS)
        app.quit()
    QUIT[:] = [quit_all]

    tray_ = None
    if not args.shot:
        tray_ = Tray(app, quit_all)
        say(f"tray up at {since_start()}")

    from PySide6.QtQml import QQmlApplicationEngine, qmlRegisterType
    from . import shims  # noqa: F401  registers the stand-in modules
    from . import wallpaper  # noqa: F401  registers OrpheusDesktop.Wallpaper
    qmlRegisterType(QUrl.fromLocalFile(str(HERE / "qml" / "PanelEdges.qml")), "OrpheusDesktop", 1, 0, "PanelEdges")
    for name in ("PanelWindow", "FloatingWindow"):
        qmlRegisterType(QUrl.fromLocalFile(str(HERE / "qml" / f"{name}.qml")), "Quickshell", 1, 0, name)
    if tray_ is not None:
        shims.PLAYER_LISTENERS.append(tray_.sync)

    engine = QQmlApplicationEngine()
    engine.setOutputWarningsToStandardError(False)    # the signal below has them; no doubles
    shims.refresh_screens(engine)
    for sig in (app.screenAdded, app.screenRemoved):
        sig.connect(lambda *_: shims.refresh_screens(engine))
    engine.warnings.connect(lambda ws: [print("qml:", w.toString(), file=sys.stderr) for w in ws])
    engine.load(QUrl.fromLocalFile(str(ROOT / "Service.qml")))
    if not engine.rootObjects():
        say("Service.qml failed to load")
        stop_daemon(daemon, adopted_too=False)
        sys.exit(1)
    say(f"QML loaded at {since_start()}")

    keep = None
    hotkeys = None
    if args.shot:
        QTimer.singleShot(1500, lambda: (args.style and call("orpheus", "style", args.style),
                                         call("orpheus", args.open)))
        QTimer.singleShot(6000, lambda: (shoot(app, Path(args.shot), engine), app.quit()))
    else:
        from . import gamemode, winsys
        if not ISOLATED:
            hotkeys = winsys.Hotkeys(fire)
            app.installNativeEventFilter(hotkeys)
            shims.attach_hotkeys(hotkeys)   # the settings page shows them and rebinds them
            tray_.attach_hotkeys(hotkeys)
            if hotkeys.failed:
                say("hotkeys taken by another app:", ", ".join(hotkeys.failed))
        # Game mode (a fullscreen game in front: widget, stage and toasts step back).
        game = gamemode.install(app)
        game.listeners.append(shims.game_changed)
        watch = QTimer(app)
        watch.timeout.connect(keeper.check)
        watch.start(1000)          # a poll() and a dict read: nothing
        keep = [tray_, launches, game, watch]

        def later():
            # Not needed for the first frame: the taskbar buttons, toasts and jump
            # list (COM, and files written), the in-game HUD (a second QML
            # window) and Discord (a pipe and a thread).
            if ISOLATED:
                return
            from . import discord, hud
            keep.append(winshell.install(app, fire, tray_.t, make_icon()))
            keep.append(hud.install(engine, engine.rootObjects()[0]))
            keep.append(discord.install())
            say(f"shell integrations up at {since_start()}")
        QTimer.singleShot(1500, later)

        if args.open != "none":
            # Open once the daemon answers (or 8 s on), so a first run lands on
            # the sign-in page rather than on "the player service isn't
            # running" for the two seconds it takes to start. Started mid-game
            # (sign-in, a launcher): do not throw a window over it.
            def first_open(tries=[0]):
                tries[0] += 1
                if not shims.STATUS["online"] and tries[0] < 40:
                    QTimer.singleShot(200, first_open)
                    return
                if gamemode.active():
                    return
                signed_out = shims.STATUS["online"] and shims.STATUS["login"] not in ("", "signed-in")
                method = "login" if signed_out and args.open == "library" else args.open
                fire(method)
                say(f"opened {method} at {since_start()}")
            QTimer.singleShot(0, first_open)
    code = app.exec()
    keeper.quitting = True
    if hotkeys:
        hotkeys.release()
    from .discord import PRESENCE
    for p in PRESENCE:
        p.stop()          # closing the pipe clears the presence
    if keeper.proc is not None and keeper.proc.poll() is None:
        stop_daemon(keeper.proc, adopted_too=False)   # quit some other way than the tray
    shims.stop_processes()     # cava/audiocap; the job would end them anyway
    say(f"quit ({code})")
    from PySide6.QtCore import qInstallMessageHandler
    qInstallMessageHandler(None)    # Qt's threads say goodbye on the way out; not news
    sys.stdout.flush()
    sys.stderr.flush()
    # Everything that matters is done. Tearing down the QML engine, its render
    # threads and PySide's wrappers at interpreter exit corrupted the heap now
    # and then (0xC0000374/0xC0000005 after the stage had been open), which
    # Windows reports as a crash; skip that teardown.
    os._exit(code)


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
