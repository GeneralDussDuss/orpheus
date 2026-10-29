<div align="center">

```
█████ ████  ████  █   █ █████ █   █ █████
█   █ █   █ █   █ █   █ █     █   █ █
█   █ ████  ████  █████ ████  █   █ █████
█   █ █  █  █     █   █ █     █   █     █
█████ █   █ █     █   █ █████ █████ █████
```

**a hi-res TIDAL player that thinks it's a terminal**

[![licence](https://img.shields.io/badge/licence-GPL--3.0--or--later-2f5bff?style=flat-square)](LICENSE)
[![version](https://img.shields.io/badge/version-0.1.0-5b8cff?style=flat-square)](manifest.json)
[![platform](https://img.shields.io/badge/platform-Omarchy%20%C2%B7%20Windows-84a9ff?style=flat-square)](#-install)
[![stack](https://img.shields.io/badge/QML%20·%20GLSL%20·%20Python-0a1020?style=flat-square)](#-how-it-fits-together)
[![stars](https://img.shields.io/github/stars/GeneralDussDuss/orpheus?style=flat-square&color=ffd98a&label=stars)](https://github.com/GeneralDussDuss/orpheus/stargazers)

**[Live demo — the real shaders, running in your browser](https://generaldussduss.github.io/orpheus-site/)**

</div>

![the player in motion](docs/media/player.gif)

### Install

**Linux ([Omarchy](https://omarchy.org))** — paste this into a terminal:

```sh
curl -fsSL https://raw.githubusercontent.com/GeneralDussDuss/orpheus/main/install.sh | bash
```

**Windows 10 / 11** — paste this into PowerShell:

```powershell
irm https://raw.githubusercontent.com/GeneralDussDuss/orpheus/main/install.ps1 | iex
```

Either one is the whole install. It adds whatever is missing, sets everything up, and
opens the player when it is done. Run the same line again to update.
[What they do, and how to undo them.](#-install)

---

## ╱╱ the idea

Most music visualizers react to **loudness**. A kick lands, the bars jump, and that is
the whole relationship. Orpheus reacts to **pace**: it estimates the tempo of what is
playing and moves the world at that speed. A 174 BPM breakbeat does not just flicker
harder than a 89 BPM doom riff — the road arrives sooner, the camera covers more ground,
the terrain rolls past faster.

The shaders never read the clock. They read a distance that the CPU integrates from the
current tempo, so when the pace changes, the world's speed changes with it.

The other half of the idea is that none of it looks like a music app. There is no title
bar, there are no rounded cards and there are no popout menus. The interface is
box-drawing characters and braille spectrum glyphs laid out in the columns and rows of
your desktop font, with a fragment shader running in the right half of the window.
Colours come from the active Omarchy theme, so it changes when your desktop does.

<table>
<tr>
<td width="50%"><img src="docs/media/prism.png" alt="Prism: a spectrum city on a winding road"></td>
<td width="50%"><img src="docs/media/horizon.png" alt="Horizon: ridgelines rolling out of a banded sun"></td>
</tr>
<tr>
<td align="center"><b>Prism</b> — a spectrum city on a winding road</td>
<td align="center"><b>Horizon</b> — ridgelines rolling out of a banded sun</td>
</tr>
</table>

> **Unofficial client.** Orpheus is not affiliated with, endorsed by or supported by
> TIDAL. It uses the unofficial [`tidalapi`](https://github.com/tamland/python-tidal)
> library and needs **your own paid TIDAL subscription**. It only streams; it does not
> download, store or decrypt anything. TIDAL's terms may not permit third-party clients.
> Whether to use one on your account is your call and your risk.

---

## ╱╱ contents

- [What you get](#-what-you-get)
- [How it fits together](#-how-it-fits-together)
- [Requirements](#-requirements)
- [Install](#-install)
- [Sign-in](#-sign-in)
- [Keybinds and usage](#-keybinds-and-usage)
- [Equalizer](#-equalizer)
- [Lyrics](#-lyrics)
- [Configuration](#-configuration)
- [Troubleshooting](#-troubleshooting)
- [Status and known issues](#-status-and-known-issues)
- [Licence](#-licence)

---

## ╱╱ what you get

| | |
|---|---|
| **The player** | A TUI window with your mixes, playlists, albums, tracks and artists, a search, a queue, and a visualizer in the right-hand rail. `Super+Shift+M`. |
| **The stage** | The same engine fullscreen, with a mini-player. `Super+Ctrl+M`. |
| **The widget** | A desktop widget that cycles styles inline — no popout. Five layer modes: `top`, `reserve`, `desktop`, `tile`, `float`. |
| **The bar** | A tiny always-on spectrum in the Omarchy bar. Click for the stage, scroll for the next style. |
| **Five styles** | Prism, Skyline, Horizon, Tunnel, Orb — plus `mini` for bar-sized surfaces, and a GPU spectrum-history pass the first two build terrain from. |
| **Hi-res** | Up to FLAC hi-res through the PKCE sign-in, lossless otherwise. The player shows which you got. |
| **More than TIDAL** | Section `8` searches YouTube and SoundCloud through `yt-dlp`, and anime through `ani-cli`. Videos play in their own window; YouTube and SoundCloud also play as audio through the same queue, equalizer and visualizer. None of it needs a TIDAL sign-in. |
| **Desktop integration** | MPRIS, so your bar, your media keys and the rest of the desktop see the track. Favourites from anywhere in the UI. The queue and position survive a service restart. |

![the desktop widget](docs/media/widget.png)

---

## ╱╱ how it fits together

Two halves that talk over a loopback socket.

```
   TIDAL ──tidalapi──┐
                     │
                 ┌───▼──────────────────────┐        ┌──────────────────────┐
                 │  orpheusd  (Python)      │  JSON  │  Quickshell plugin   │
                 │                          │◄──────►│  (QML + GLSL)        │
                 │  · tidalapi session      │  :47837│                      │
                 │  · mpv over JSON IPC     │        │  · Library / Stage   │
                 │  · MPRIS over dbus-next  │        │  · Widget / BarWidget│
                 │  · queue + resume.json   │        │  · 7 fragment shaders│
                 └───┬──────────────────────┘        └──────────▲───────────┘
                     │                                          │
                    mpv ──► PipeWire ──────────► cava ──────────┘
                                                 32 bands @ 30/60 Hz
```

- **`orpheusd/`** — the daemon. `tidal.py` owns the session and the catalogue, `player.py`
  drives `mpv` over its JSON IPC (launched `--load-scripts=no --media-controls=no` so
  mpv's own MPRIS stays out of the way), `mpris.py` publishes the standard interface.
  It serves a long-polling `/status` plus `/play`, `/control/*`, `/favorite`, `/liked`
  and `/login/*` on `127.0.0.1:47837`.
- **`*.qml`** — the shell plugin. `Service.qml` is the always-on half: it runs `cava`,
  detects beats, reads theme colours live and registers the IPC handler. `Library.qml` is
  the player window, `Stage.qml` the fullscreen one, `Widget*.qml` the desktop widget,
  `BarWidget.qml` the bar spectrum, `Viz.qml` the shader host.
- **`shaders/`** — the GLSL. `_common.glsl` is inlined at each `//#common` line by
  `build-shaders.sh`; `history.frag` is a feedback pass that keeps a 32×40 spectrum
  history on the GPU so Prism and Horizon can build terrain out of the past.

Tempo is estimated by autocorrelating the spectral-flux envelope at a fixed 50 Hz. The
octave is chosen against a target derived from onset density, with a veto on any
candidate that would imply more than 3.5 onsets per beat — that is what stops a dense
breakbeat locking to half-time.

---

## ╱╱ requirements

- **Linux with [Omarchy](https://omarchy.org)** (Hyprland and its Quickshell-based shell),
  where Orpheus is a shell plugin, **or Windows 10 / 11**, where the same player runs as a
  tray app. Not macOS, and not another Linux desktop without the Omarchy shell.
- Linux: `mpv`, `cava`, `uv` and `jq`. The installer checks for them and offers to install
  anything missing. PipeWire is expected (the visualizers read its monitor).
- Windows: `winget` (built into Windows 10 and 11 as App Installer). The installer uses it
  for git, uv, mpv, cava and yt-dlp; mpv's installer asks for administrator approval once.
- Optional: `yt-dlp` for YouTube and SoundCloud, `ani-cli` for anime, `curd` for anime
  with AniList sync.
- Optional: a paid TIDAL subscription, for the music library. Everything else works
  without one.
- To rebuild shaders only: `qsb` from Qt 6 shader tools. The compiled `shaders/*.qsb`
  files are committed, so a normal install does not need it.

Orpheus has been run on very few machines so far (Arch-based Omarchy, Hyprland 0.56). If
you get it working somewhere else, or it breaks, an issue is genuinely useful.

---

## ╱╱ install

### Linux (Omarchy)

```sh
curl -fsSL https://raw.githubusercontent.com/GeneralDussDuss/orpheus/main/install.sh | bash
```

Want to read it first? It is [one short script](install.sh). Prefer not to pipe into
bash? Either of these does the same thing:

```sh
# through Omarchy's plugin manager
omarchy plugin add https://github.com/GeneralDussDuss/orpheus
~/.config/omarchy/plugins/orpheus/install.sh

# or a clone anywhere
git clone https://github.com/GeneralDussDuss/orpheus && ./orpheus/install.sh
```

The installer:

- checks for Omarchy and the tools above, and offers `omarchy pkg add` for what is missing
- links the plugin into `~/.config/omarchy/plugins/orpheus` (if it is not there already)
- builds the Python environment with `uv` and starts `orpheusd` as a systemd user service
- puts `orpheus` on your `PATH` and adds launcher entries
- links `hypr/orpheus.lua` into `~/.config/hypr` and adds one `require` line to
  `hyprland.lua` (backed up first) for the window rules and keys
- enables the plugin, with the bar widget on the right, restarts the shell and opens the player

It is safe to re-run, and that is how you update: the one-liner again, or `git pull` and
`./install.sh`. Add `--yes` (`| bash -s -- --yes`) to skip the question before it installs
packages. `install.sh --check` only reports what is missing, and `install.sh --uninstall`
undoes all of it, keeping your sign-in and settings in `~/.local/state/orpheus`.

The shell does not hot-reload plugins, so after changing any QML, run `omarchy restart shell`.

### Windows

```powershell
irm https://raw.githubusercontent.com/GeneralDussDuss/orpheus/main/install.ps1 | iex
```

[The script](install.ps1) installs whatever is missing with winget (git, uv, mpv, cava,
yt-dlp), fetches Orpheus into `%LOCALAPPDATA%\Orpheus\app`, builds its Python environment,
adds **Orpheus** to the Start menu and opens it. It lives in the tray: click the icon for
the player, right-click for the visualizer and the mini player. The player, the
visualizers and the video section are the same code as on Linux; anime is Linux-only for
now, and so are the global keybinds and the bar widget.

Run the same line again to update. To remove it, keeping your sign-in and settings in
`%LOCALAPPDATA%\Orpheus\state`:

```powershell
& "$env:LOCALAPPDATA\Orpheus\app\install.ps1" -Uninstall
```

Windows support is new: it is tested on every change in CI, but has run on few real
machines so far. If something is off, an issue helps a lot.

### Rebuilding the shaders

`shaders/*.frag` are compiled to `.qsb` by `build-shaders.sh`, which inlines
`shaders/_common.glsl` at each `//#common` line and runs `qsb --qt6`.

`qsb` ships with Qt 6's shader tools. On Arch it is in `qt6-shadertools` and installs to
`/usr/lib/qt6/bin/qsb`, which is **not on `PATH`**. The script falls back to that path on
its own; for anywhere else, set `QSB`:

```sh
./build-shaders.sh
QSB=/path/to/qsb ./build-shaders.sh
```

The std140 uniform block in `_common.glsl` must match `Viz.qml` exactly, or the
visualizer renders black.

---

## ╱╱ sign-in

Press `Ctrl+Shift+O` (once bound, see below), or run `orpheus login`. The sign-in page
offers two flows:

- **Standard sign-in** (a device link). This streams at most lossless FLAC.
- **Hi-res sign-in** (`h`, PKCE). It opens a TIDAL login in your browser, and you paste
  the redirect URL back into the page. **Hi-res streaming only works with this flow**:
  the daemon reports `hires` only when the session is a PKCE session, and otherwise falls
  back to lossless.

The page shows `signed in as <user> · hi-res unlocked` when it worked. The session is
kept in `~/.local/state/orpheus/tidal-session.json` — treat that file as a credential.

---

## ╱╱ keybinds and usage

The installer binds these through `hypr/orpheus.lua`. `Super+Shift+M` is Omarchy's own
music key (Spotify by default), and Orpheus takes it over. To bring your own keys
instead, put `orpheus_bindings = false` in `hyprland.lua` above the
`require("hypr.orpheus")` line; the window rules stay.

| key | |
|---|---|
| `Super+Shift+M` | the player |
| `Super+Ctrl+M` | fullscreen stage |
| `Super+Alt+M` | the desktop widget |
| `Ctrl+Shift+O` | sign-in |

And in the player: `e` opens the equalizer, `L` the lyrics, `y` copies a link to
whatever the cursor is on.

In the player: `v` cycles the visualizer plane, `V` opens the stage, `1`–`7` switch tabs
(home, search, mixes, playlists, albums, tracks, artists), `↵` plays, `space` pauses,
`f` favourites, `/` searches, `q` closes.

**Sharing.** `y` copies a TIDAL link to the clipboard — for the row under the cursor,
not necessarily what is playing, since what you want to send is usually what you are
looking at. `Y` copies a [song.link](https://song.link) instead, which opens on whatever
service the person you send it to actually uses; a bare TIDAL link is no use to a friend
on Spotify. Tracks and albums have a universal form, artists and playlists do not, and a
mix has no link at all — its id means nothing outside your account.

`orpheus share` does the same from a keybind with nothing open (`-u` for the universal
link). It asks the daemon rather than the shell, because the window's status poll only
runs while a window is on screen:

```lua
o.bind("SUPER + SHIFT + C", "Copy song link", "orpheus share")
```

**CLI.** `bin/orpheus [open|stage|close|toggle|status|share]` is idempotent: `open` and
`close` check state first, `toggle` flips the player, `status` prints the shell's status
JSON. Apart from `share`, everything is an IPC call; nothing is launched or kept alive.
That is what makes it safe for a `.desktop` entry, which a launcher may fire twice.

**The desktop widget** is configured through one method, `widget <key> <value>`:

| key | values |
|---|---|
| `enabled` | `on` · `off` · `toggle` |
| `style` | `compact` · `full` |
| `corner` | `top-left` · `top-right` · `bottom-left` · `bottom-right` |
| `layer` | `top` · `reserve` · `desktop` · `tile` · `float` |
| `viz` | `prism` · `skyline` · `horizon` · `tunnel` · `orb` |
| `monitor` | a monitor name, or empty for wherever it lands |

`layer` is the one that decides how it behaves: `desktop` pins it behind your windows like
a wallpaper, `tile` makes it a real window Hyprland lays out, `float` floats it, `top`
sits above everything and `reserve` carves out space for it. Settings persist, so you set
them once. Styles also cycle on the widget itself — scroll it or right-click — because
this player does not do popout menus.

Or call the shell directly — `omarchy-shell orpheus <method>` — with methods
`status toggle show hide library login eq lyrics style railViz nextRailViz nextStyle miniPlayer
placement widget`. Note the widget's visualizer is `widget viz <style>`; there is no
`widgetViz`.

---

## ╱╱ equalizer

Ten bands at 31, 62, 125, 250, 500&nbsp;Hz and 1, 2, 4, 8, 16&nbsp;kHz, ±12&nbsp;dB in half-decibel
steps. The two end bands are shelves rather than peaks, because a peaking filter at 31&nbsp;Hz
with Q&nbsp;1.4 has almost no effect by 20&nbsp;Hz — "lift the sub-bass" should do what it says.

It runs inside mpv as a filter chain, not as a PipeWire sink. That means it follows the
output device automatically, affects nothing but Orpheus, and adds no dependency. **A flat
or disabled EQ removes the filter entirely**, so the signal path is untouched rather than
running through a unity-gain biquad.

**Headroom, and why a boost can sound quieter.** Boosting a band cannot make anything
louder — there is nothing above full scale. So the preamp pulls the whole signal down by
the size of the largest boost: lift 31&nbsp;Hz by 6&nbsp;dB and the bass lands at net zero while
everything else drops 6. Relative to each other the bass is +6; absolutely, the track got
quieter. That is what stops it clipping, and it matters here because mpv already runs with
`--replaygain-clip=no`, so material is permitted above 0&nbsp;dBFS before the EQ touches it.

You can take the headroom back. `[` and `]` move the preamp half a decibel at a time and
`\` returns it to automatic. Taking less than the curve needs is allowed and says **may
clip** while it is.

```sh
curl -s 127.0.0.1:47837/eq                  # bands, presets, current state
curl -X POST 127.0.0.1:47837/eq -d '{"preset":"loudness","enabled":true}'
curl -X POST 127.0.0.1:47837/eq -d '{"band":0,"gain":4.5}'   # one band, for a slider
curl -X POST 127.0.0.1:47837/eq -d '{"enabled":false}'       # bypass
```

Six tone presets ship with it: Flat, Bass Lift, Vocal, Loudness, Tame Treble and Speech.

Open it with `e` in the player, or `omarchy-shell orpheus eq` to open the window straight
onto it. Inside: `h`/`l` pick a band, `j`/`k` move it by half a decibel, `J`/`K` coarse,
`0` zeroes a band, `z` zeroes all, `p` cycles presets, `b` bypasses, `esc` goes back.
`[` and `]` set the preamp, `\` returns it to automatic. The bands also take the mouse:
click or drag to set one, scroll to nudge, middle click to zero, right click to bypass.

The transport bar carries a small readout beside the volume — eight block glyphs
summarising the ten bands, accented while a filter is live and a flat dim line when it is
not, so you can tell at a glance whether something is shaping the sound. Left click opens
the pane, right click bypasses without leaving the page.

### Headphone corrections

Orpheus ships **no measurement data**, deliberately. The obvious source is
[AutoEq](https://github.com/jaakkopasanen/AutoEq), whose MIT licence covers its code and
not its data — the measurements come from oratory1990, Rtings, Super Review and others, none
of whom have granted redistribution, and the maintainer confirms the distinction in AutoEq
issue [#790](https://github.com/jaakkopasanen/AutoEq/issues/790). So Orpheus ships the
importer instead, and the numbers stay on your machine.

Find your headphones in AutoEq's results, take the **`FixedBandEQ.txt`** (not
`ParametricEQ.txt` or `GraphicEQ.txt` — the fixed-band file is already fitted to these exact
ten centres) and post it:

```sh
curl -X POST 127.0.0.1:47837/eq/presets -H 'Content-Type: application/json' \
  --argjson text "$(jq -Rs . < 'Sennheiser HD 6XX FixedBandEQ.txt')" \
  -d "{\"name\":\"Sennheiser HD 6XX\",\"text\":$(jq -Rs . < 'Sennheiser HD 6XX FixedBandEQ.txt')}"
```

It lands in `~/.local/state/orpheus/eq-presets.json` and appears alongside the tone presets.
`DELETE /eq/presets/{id}` removes one.

One thing the importer will warn you about: AutoEq fits out to 20&nbsp;kHz, above the range
where coupler measurements are reliable, so the 16&nbsp;kHz band often comes out as a large cut
that is an artefact of the fit rather than anything you would hear. The warning is advisory —
your data is imported as written.

---

## ╱╱ lyrics

`L` in the player, or `omarchy-shell orpheus lyrics`. Synced lyrics scroll with the track,
the current line lit, lines already sung dimmed behind it.

TIDAL is asked first, since your subscription already carries timed lyrics for a lot of
the catalogue. When it has none, or has only unsynced words, [LRCLIB](https://lrclib.net)
is asked — it is free, needs no key, and often has timings TIDAL lacks. Failing both, the
plain words are shown unsynced, and failing that it says so.

Results are cached under `~/.cache/orpheus/lyrics`, including the misses: plenty of tracks
have no lyrics anywhere and asking two services again on every play is rude to both.
**No lyrics are bundled with Orpheus** — they are fetched at play time and cached locally.

Community LRC files are often a fraction of a second out. `[` and `]` nudge the sync a
quarter second at a time and `\` resets it.

---

## ╱╱ configuration

Little is configurable, and most of it is by hand.

- **Audio quality** is picked in the player (`high` 320k, `lossless` FLAC, `hires`); the
  choice is stored in `~/.local/state/orpheus/daemon.json`.
- **The EQ curve** is stored in the same file and restored before the first track plays.
  Imported headphone corrections live beside it in `eq-presets.json`.
- **Port.** The daemon defaults to `47837`, settable with `--port` or `ORPHEUS_PORT`.
  `Api.qml` hardcodes `47837`, so changing the daemon's port also means editing the QML.
- **State**: `~/.local/state/orpheus/` (session, prefs, `resume.json` — the queue and
  position are restored on start). **Cache**: `~/.cache/orpheus/`. **mpv socket**:
  `$XDG_RUNTIME_DIR/orpheus/mpv.sock`.
- **Colours and font** follow the Omarchy theme and font. There is nothing to set.

---

## ╱╱ troubleshooting

- **Nothing happens on the keybind.** Check the plugin is loaded:
  `omarchy-shell orpheus status`. If it errors, the plugin symlink or the shell restart
  is missing.
- **Player opens but is empty or offline.** Check the daemon:
  `systemctl --user status orpheusd`, `journalctl --user -u orpheusd -e`. A quick probe
  is `curl -s 127.0.0.1:47837/status`.
- **Only lossless, no hi-res.** You signed in with the standard flow. Sign in again and
  press `h`.
- **No sound or no visualizer.** The visualizer reads PipeWire through `cava`; check
  `command -v cava mpv`. (Orpheus has nothing to do with your DAC — if the whole desktop
  is silent, that is elsewhere.)
- **The visualizer is flat while music is obviously playing.** Orpheus pins `cava` to the
  monitor of your *default sink* and follows it when you switch output. If it ever gets
  out of step, check which source `cava` actually grabbed:

  ```sh
  pactl get-default-sink                       # where audio is going
  grep '^source' ~/.local/state/orpheus/cava.conf   # where cava was told to listen
  pactl list source-outputs | grep -A6 cava    # where cava actually is
  ```

  Those three should agree. If the config says `source = auto`, `pactl` could not be
  reached and cava is guessing — that is the old behaviour, and it breaks as soon as you
  change output device.
- **Visualizer is a black rectangle after a shader edit.** Rebuild with
  `./build-shaders.sh` and restart the shell. A uniform-block mismatch between
  `_common.glsl` and `Viz.qml` is the usual cause.
- **Restarting `orpheusd` interrupts playback** for about a second; resume brings it back.

---

## ╱╱ status and known issues

Orpheus is a personal project. It has been run on one desktop, by one person, for a
couple of weeks. It works well enough that it is the author's daily player — and it has
sharp edges that only one machine's worth of testing can leave.

Honest list, at the time of writing:

- **Sparse drum & bass can still read at half-time.** The octave rule used to prefer the
  candidate nearest 120 BPM, which locked a ~174 BPM track to 86 and rendered it *slower*
  than rest pace. It now aims at a target derived from onset density and vetoes any
  candidate needing more than 3.5 onsets per beat, which fixes dense breakbeats. Around
  4 onsets/s the two readings are genuinely ambiguous and it can still pick half-time.
- **`tempoConfidence` measures peak sharpness, not correctness.** A confident reading is
  not necessarily a right one — a half-time lock produces a very sharp peak.
- **An intermittent crash when closing the stage.** Twice in one session, closing the
  stage took the whole shell down inside Qt's item destruction. It did not reproduce
  across 90 scripted open/close cycles, so the trigger is not known. Unresolved.
- **mpv's memory grows over a long session.** After 7¼ hours of playback mpv held 1.19 GB
  of anonymous heap with its demuxer cache at the stock 150 MiB the whole time, so
  buffering does not explain it. The budget is now capped at 48 MiB forward / 16 MiB
  back, which bounds the buffers but is not confirmed to be the cause. Restarting
  `orpheusd` reclaims it and resume restores the queue. Under investigation.
- **The plugin costs roughly 15% of shell CPU while playing.** One machine, eyeballed —
  not a benchmark.
- **Toggling the plugin off and on at runtime froze the shell once.** Teardown on unload
  has since been added, but the original freeze has not been reproduced to confirm the
  fix.
- **TIDAL is the only provider, on purpose.** Spotify cannot legally stream to a
  third-party client at all, and a provider abstraction for one provider costs more than
  it returns.

If you run it and something breaks, [open an issue](https://github.com/GeneralDussDuss/orpheus/issues).
If you like it, a ⭐ is how the author finds out anyone else is running it.

---

## ╱╱ licence

**[GPL-3.0-or-later](LICENSE).** It sits naturally on this stack: both Quickshell and
tidalapi are LGPL-3, so there is no compatibility friction.

The showcase site is a separate repo
([orpheus-site](https://github.com/GeneralDussDuss/orpheus-site), CC BY-SA 4.0) and
carries the screenshots, the motion clips and a browser port of these shaders you can
drive yourself.
