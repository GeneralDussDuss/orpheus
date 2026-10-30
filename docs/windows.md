# Working on the Windows build

Orpheus on Windows is the same daemon and the same QML as on Linux. What differs is
the host: on Linux the QML runs as a Quickshell plugin inside the Omarchy shell; on
Windows a small PySide6 app (`orpheusd/desktop/`) loads it, with stand-ins for the
Quickshell and Omarchy types it uses.

## Who owns what

Two people (or sessions) work on Orpheus at once, one per OS, all on `main`.

| Area | Owner |
| --- | --- |
| `orpheusd/desktop/**`, `install.ps1`, `.github/workflows/windows.yml`, the `WINDOWS` branches in `orpheusd/system.py` | Windows |
| `install.sh`, the bar widget, `shaders/`, Quickshell-only behaviour, anime on Linux | Linux |
| The QML (`*.qml`, `*.js`) and the daemon core (`orpheusd/*.py`) | shared |

For shared files: `git pull --rebase` before starting and before pushing, keep commits
small, and branch on the OS instead of changing behaviour for both
(`Qt.platform.os === "windows"` in QML, `WINDOWS` from `orpheusd.system` in Python).
The Windows workflow runs on every push that touches the daemon, the QML, the shaders
or the installer; check it went green. Linux is checked by hand on Omarchy.

## Running it from a checkout

Do not work in `%LOCALAPPDATA%\Orpheus\app`: that is the installed copy, a shallow
clone that `install.ps1` updates and the uninstaller deletes. Use your own clone:

```powershell
git clone https://github.com/GeneralDussDuss/orpheus
cd orpheus
uv sync --extra desktop
uv run orpheus-desktop                # tray app; starts its own daemon
uv run orpheus-desktop --no-daemon    # use a daemon you started yourself
uv run orpheusd --port 47837          # the daemon alone, logs to the console
```

Quit the installed copy first (tray → quit), since only one instance runs at a time
and the second hands over to the first.

Useful flags: `--open library|stage|widget|none`, `--style <name>`,
`--shot <dir>` (render each window off-screen to PNGs, with a throwaway config so your
real settings are untouched), `--write-icon <path.ico>`. `ORPHEUS_HOME` points the
config somewhere else; `ORPHEUS_MPV` points at a specific `mpv.exe`.

Logs: `%LOCALAPPDATA%\Orpheus\state\desktop.log` and `orpheusd.log`. Under `pythonw`
there is no console, so everything goes there.

## How the pieces fit

- `orpheusd/system.py`: per-OS folders (`%LOCALAPPDATA%\Orpheus\{state,cache}`), finding
  mpv and Curd where winget and other installers put them (a fresh install is not on
  PATH until a new shell), and mpv's JSON IPC, which is a named pipe
  `\\.\pipe\orpheus-<name>-<pid>` on Windows and a Unix socket on Linux.
- `orpheusd/desktop/shims.py`: the stand-ins (`Process`, `FileView`, `IpcHandler`,
  `Quickshell`, `WlrLayershell`, `Hyprland`, `Color`, `Style`, ...). If the QML starts
  using a new Quickshell type, it needs a shim here or the Windows app will not load.
- `orpheusd/desktop/qml/`: `PanelWindow` and `FloatingWindow` as plain frameless Qt
  windows, placed from their anchors and margins.
- `orpheusd/desktop/winsys.py`: global hotkeys (Win+Alt+M/V/P through `RegisterHotKey`)
  and "Start with Windows" (the HKCU Run key).
- `orpheusd/desktop/__main__.py`: tray, single instance (`QLocalServer`, listening before
  the QML loads so a quick second launch is not lost), starting the daemon, the icon.
- Media keys and the Windows media overlay come from mpv's `--media-controls=yes`.
  Next/previous are rebound to `script-message orpheus next|previous` so they go
  through Orpheus' queue, and each file gets a `force-media-title` so the overlay shows
  "artist — title" instead of a URL.
- Visualizers: cava's Windows build (`karlstav.cava`) captures the default output on its
  own, so the generated config has no `[input]` section.
- Anime is Curd only. `install.ps1` runs Curd's own installer (per user, to
  `%APPDATA%\Curd\curd.exe`, not on PATH); `c` in section 8 opens it in a new console,
  where it plays through the mpv it bundles. ani-cli is a bash script and does not run.

## Gaming: game mode, the HUD, Discord

- **Game mode** (`orpheusd/desktop/gamemode.py`): every 2 s it asks
  `SHQueryUserNotificationState` (D3D fullscreen, busy, presentation) and looks at the
  foreground window: one that covers its whole monitor, has no caption, and is neither
  the desktop/taskbar nor an Orpheus window counts as a game. Borderless games often
  read as "accepts notifications", which is why the window check is there. It turns on
  at once and off after two quiet polls, so an alt-tab does not bring everything back.
  While it is on: the widget's loaders are off, every stage placement hides (the overlay
  and the fullscreen show are topmost windows), toasts are skipped, and the `--open`
  window is not shown over a game Orpheus was started during. Nothing is written to
  config.json, and it all comes back when the game goes. QML reads it as
  `OrpheusGame.gameMode` (Service.qml's `gameMode`). Config: `"gameMode": "auto" | "off"`.
- **In-game HUD** (`hud.py`, `qml/Hud.qml`): a small card (cover, title, artist, a mini
  spectrum in the theme's colours) that slides in for 4 s on a track change while game
  mode is on, and whenever the `hud:show` hotkey fires (Win+Alt+N, falling back to
  Win+Alt+I, then Win+Alt+U). The window is `WindowTransparentForInput |
  WindowDoesNotAcceptFocus | Tool | WindowStaysOnTopHint` plus `WS_EX_NOACTIVATE |
  WS_EX_TRANSPARENT | WS_EX_LAYERED | WS_EX_TOOLWINDOW`, shown with `SW_SHOWNOACTIVATE`,
  so clicks go straight through it to the game and it never takes focus. Unlike the
  stage, it is meant to be click-through. It is hidden between appearances, because an
  idle topmost window over a game can still cost the game DWM's direct-flip path.
  Config: `"hud": "on" | "off"` (track-change pop-ups; the hotkey works either way),
  `"hudCorner": "top-left" | "top-right" | "bottom-left" | "bottom-right"`.
  **Exclusive fullscreen:** a game that owns the display through an exclusive D3D
  swapchain bypasses the desktop compositor, and nothing (the HUD, the Game Bar,
  Discord's own overlay) can draw over it. Most modern games, Deadlock included, run
  borderless/flip-model, which DWM composes, and topmost overlays show there. If the
  HUD never appears in a game, switch the game to borderless or windowed fullscreen.
- **Discord Rich Presence** (`discord.py`): Discord's local IPC, the named pipe
  `\\.\pipe\discord-ipc-0` to `-9`. Each frame is an 8-byte little-endian header
  (opcode, length) followed by JSON: a HANDSHAKE (op 0, `{"v": 1, "client_id": ...}`),
  then SET_ACTIVITY frames (op 1). It shows "Listening to" with the title, artist, cover
  (the track's own https URL) and a progress bar. It clears on pause or stop and
  reconnects within about 15 s of Discord restarting. It needs your own Discord
  application:
  1. <https://discord.com/developers/applications>, then **New Application**, and name
     it **Orpheus**, since Discord shows that name.
  2. Copy the **Application ID** into `config.json`: `"discordClientId": "1234..."`.
     Empty or missing means off.
  3. Optional: under **Rich Presence -> Art Assets**, upload Orpheus's icon with the key
     `orpheus` (`python -m orpheusd.desktop --write-icon orpheus.png` writes it at 1024
     px). It becomes the small badge on the cover.
  The settings page's *gaming* section shows what game mode sees and Discord's state.

## Gotchas already paid for

- Windows refuses to replace a file Qt is watching: `FileView.setText` stops watching,
  retries `os.replace`, then watches again.
- A venv's `pythonw.exe` relaunches the base Python, so running processes do not live
  under the app folder. `install.ps1 -Uninstall` finds them by command line, then their
  children and grandchildren (mpv and cava hold the folder as their working directory).
- The workflow's `paths:` filter must list every file it tests; a file missing from it
  means fixes to that file are never checked.
- Off-screen rendering in CI needs `QT_QPA_FONTDIR=C:\Windows\Fonts`, or every glyph is
  a box.
- On a CI runner Win+Alt+M was already taken. The tray only lists hotkeys that actually
  registered.

## Still unproven on a real PC

Transport glyphs (icons vs boxes), cava following the music, the video window, whether
Win+Alt+M is free, media keys and the overlay, and Curd finding streams (the released
Curd still points at a dead source until Wraient/curd#125 ships; `curd -u` updates it).
