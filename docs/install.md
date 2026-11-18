# Install, update, uninstall

## Linux (Omarchy)

```sh
curl -fsSL https://raw.githubusercontent.com/GeneralDussDuss/orpheus/main/install.sh | bash
```

Want to read it first? It is [one short script](../install.sh). Prefer not to pipe into bash? Either
of these does the same:

```sh
# through Omarchy's plugin manager
omarchy plugin add https://github.com/GeneralDussDuss/orpheus
~/.config/omarchy/plugins/orpheus/install.sh

# or a clone anywhere
git clone https://github.com/GeneralDussDuss/orpheus && ./orpheus/install.sh
```

The installer:

- checks for Omarchy, `mpv`, `cava`, `uv` and `jq`, and offers `omarchy pkg add` for what is missing
- links the plugin into `~/.config/omarchy/plugins/orpheus` (if it is not there already)
- builds the Python environment with `uv` and starts `orpheusd` as a systemd user service
- puts `orpheus` on your `PATH` and adds launcher entries
- links `hypr/orpheus.lua` into `~/.config/hypr` and adds one `require` line to `hyprland.lua`
  (backed up first) for the window rules and keys
- enables the plugin with the bar widget on the right, restarts the shell and opens the player

It is safe to re-run, and that is how you update: the one-liner again, or `git pull` and `./install.sh`.

| flag | |
|---|---|
| `--yes` (`\| bash -s -- --yes`) | don't ask before installing packages |
| `--check` | only report what is missing |
| `--uninstall` | undo all of it, keeping your sign-in and settings in `~/.local/state/orpheus` |

The shell does not hot-reload plugins, so after changing any QML, run `omarchy restart shell`.

## Windows 10 / 11

```powershell
irm https://raw.githubusercontent.com/GeneralDussDuss/orpheus/main/install.ps1 | iex
```

[The script](../install.ps1) installs what is missing with winget (git, uv, mpv, cava, yt-dlp) plus
Curd for anime, fetches Orpheus into `%LOCALAPPDATA%\Orpheus\app`, builds its Python environment, adds
**Orpheus** to the Start menu and Settings → Apps, and opens it. mpv's installer asks for administrator
approval once. `winget` is built into Windows 10 and 11 as App Installer. winget's `yt-dlp` brings
ffmpeg and the desktop extra brings numpy, so drop detection works out of the box.

Run the same line again to update. To remove it, use Uninstall in Settings → Apps, or this; either way
keeps your sign-in and settings in `%LOCALAPPDATA%\Orpheus\state`:

```powershell
& "$env:LOCALAPPDATA\Orpheus\app\install.ps1" -Uninstall
```

Windows support is newer: it is tested on every change in CI, but has run on few real machines so far.
If something is off, an issue helps a lot. The developer guide is [windows.md](windows.md).

## ORPHEUS//WIN: what the Windows edition adds

*Recorded on Windows 10 / 11. Same daemon, same QML as Linux, plus a lot of host.* The Windows edition
is a PySide6 tray app that loads the player and supplies stand-ins for the Quickshell and Omarchy
pieces. Click the tray icon for the player, right-click for the visualizer, the mini player and
**Start with Windows**. The bar widget is Linux-only.

- **Themes.** 8 originals (acid-rave, aurora, chrome-heart, lyre, styx, sub-bass, underworld, vinyl)
  and 19 [Omarchy](https://omarchy.org) palettes, in the tray's Theme menu. A **theme builder** turns
  three colours (background, text, accent) into a whole palette, with a dice roll, and saves it to
  `~/.config/orpheus/themes`. **From Album Art** pulls a palette from the cover of what is playing.
- **The show.** A fullscreen show, a **wallpaper mode** that sits behind your desktop icons, and
  **kinetic lyrics** over the visualizer (entrance: wave, rain or plain). Trails and bloom are settings, and
  the visualizer lands style changes on the downbeat.
- **Only Orpheus.** The visualizers capture the app's own audio through **WASAPI process loopback**
  (Windows 10 2004 and later), so a game or a call in the background does not drive them. Where that is
  missing, they fall back to `cava` on the whole output.
- **Controls.** Rebindable global hotkeys (see [keys.md](keys.md#windows-rebindable-in-settings)).
- **Windows shell.** Taskbar thumbnail buttons (previous, play / pause, next), toasts on track change,
  a jump list, a frameless window drawn entirely by the TUI, and **glass**, a blurred see-through player.
- **Game mode.** Notices a fullscreen game, stands the widget, visualizer and toasts down, and brings them
  back afterwards. An **in-game HUD** (cover, title, a mini spectrum) slides in on track changes,
  click-through and never taking focus. **Discord Rich Presence** with your own application ID.
- **Anime** is Curd's: in section `8`, `c` opens it in its own console with AniList sync.
- **Your shaders** need `qsb` copied in; see [shaders.md](shaders.md).
