# Configuration

Almost everything is in the settings pane (`,` in the player, `/` searches it). This page is for
doing it by hand, from a script or from a keybind. Colours and font follow the Omarchy theme and font;
there is nothing to set.

## Where things live

| what | Linux | Windows |
|---|---|---|
| settings | `~/.config/orpheus/config.json` | same path under your home |
| state: sign-in, quality, EQ, queue | `~/.local/state/orpheus/` | `%LOCALAPPDATA%\Orpheus\state` |
| cache: lyrics, drop maps, AutoEQ | `~/.cache/orpheus/` | `%LOCALAPPDATA%\Orpheus\cache` |
| your shaders | `~/.config/orpheus/shaders` | `%LOCALAPPDATA%\Orpheus\shaders` |
| mpv socket | `$XDG_RUNTIME_DIR/orpheus/mpv.sock` | |

Audio quality (`high` 320k, `lossless` FLAC, `hires`) is picked in the player. The drop map needs
`ffmpeg` on `PATH` and numpy (`uv sync --extra analysis`, or `--extra desktop`); maps are cached in
`~/.cache/orpheus/analysis/`.

In the state folder: `tidal-session.json` is the TIDAL session (treat it as a credential),
`daemon.json` holds the audio quality, the EQ curve and the chosen AutoEQ correction (restored before
the first track plays), `eq-presets.json` your imported presets, and `resume.json` the queue and
position, restored on start.

## config.json

| key | default | |
|---|---|---|
| `style` | `prism` | the stage's style (any of the 20, or `@name` for yours) |
| `railViz` | `prism` | the visualizer in the player's rail; `off` shows the album art |
| `scene` | `viz` | the stage opens on `viz` or `cassette` |
| `deckLook` | `shell` | the cassette deck's look: `shell` or `light` |
| `placement` | `overlay` | the stage: `overlay` (a card over everything), `desktop`, `fullscreen` |
| `showMonitor` | `""` | pin the stage to a monitor by name; empty = the focused one when it opens |
| `cardPos` | `null` | where you dragged the visualizer card (fractions); `null` = centred |
| `miniPlayer` | `true` | the stage's mini player |
| `syncViz` | `true` | the widget shows whatever the stage shows |
| `bloom` · `feedback` | `subtle` | `off`, `subtle` or `full` |
| `ambient` | `subtle` | `off`, `subtle` or `vivid` |
| `autoStyle`, `pilgrimage` | `false` | stage flags |
| `trackTitle`, `autoQuality`, `director`, `beatLock` | `true` | stage flags |
| `lyricsOverViz`, `showFps` | `false` | stage flags |
| `pilgrimRoute` | | the styles Pilgrimage travels through |
| `dropMap` | `true` | analyse tracks ahead for the drop map (daemon and player) |
| `dropMapLeadMs` | `30` | how early the player acts on a mapped beat |
| `dropFx`, `titleFx`, `pulseUi`, `bootScreen` | `true` | effects and the boot screen |
| `endless` | `true` | keep going with TIDAL radio when the queue runs out |
| `crossfade` | `0` | seconds, 2 to 12; 0 is gapless (and never within an album) |
| `remote` | `off` | `lan` turns on the phone remote (port `remotePort`, 47838; pair by QR code in settings) |
| `navidromeUrl`, `navidromeUser`, `navidromePass` | | a Navidrome server; also in settings |
| `shadertoyKey` | | your shadertoy.com app key, so pasted links can fetch shaders |
| `listenbrainz…`, `lastfm…` | | scrobbling, set from settings ▸ integrations |
| `widget` | see below | the desktop widget |

## The widget

Set it with `omarchy-shell orpheus widget <key> <value>`. Settings persist.

| key | values |
|---|---|
| `enabled` | `on` · `off` · `toggle` |
| `style` | `compact` · `full` (horizontal), `cassette` · `monolith` · `reference` · `field` (vertical) |
| `corner` | `top-left` · `top-right` · `bottom-left` · `bottom-right` (default) |
| `layer` | `top` (default) · `reserve` · `desktop` · `tile` · `float` |
| `viz` | any style; with `syncViz` on this sets the stage's style too |
| `monitor` | a monitor name, or empty for wherever it lands |

`layer` decides how it behaves: `desktop` pins it behind your windows like a wallpaper, `tile` makes it
a real window Hyprland lays out, `float` floats it (tall styles get their own centred window rule),
`top` sits above everything and `reserve` carves out space for it. Styles also cycle on the widget
itself (scroll or right-click), because this player does not do popout menus.

## Environment

| variable | |
|---|---|
| `ORPHEUS_PORT` | the daemon's port (default `47837`, or `--port`). `Api.qml` hardcodes 47837, so changing it means editing the QML too |
| `ORPHEUS_FFMPEG` | the ffmpeg the drop map uses |
| `ORPHEUS_SHADERS` | moves your shader folder |
| `ORPHEUS_QSB` | the shader compiler (set but empty = none) |

## IPC

`omarchy-shell orpheus <method> [args]`. Each returns the status JSON, or an error that names the allowed values.

| method | |
|---|---|
| `status` · `toggle` · `show` · `hide` | the stage |
| `library` · `login` · `eq` · `lyrics` · `settings` | the player, opened on a page |
| `style <name>` · `nextStyle` | the stage's style |
| `railViz <name>` · `nextRailViz` | the player's rail |
| `scene viz\|cassette\|next` · `cassette` | the stage's scene; `cassette` toggles the deck (opening the stage on it if closed) |
| `miniPlayer` · `placement` · `showMonitor <name>` | stage layout |
| `autoStyle` `pilgrimage` `trackTitle` `lyricsOverViz` `autoQuality` `showFps` `director` `beatLock` `dropMap` | `on` · `off` · `toggle` |
| `pilgrimNext` | Pilgrimage's next leg |
| `bloom` · `feedback` | `off` · `subtle` · `full` · `next` |
| `widget <key> <value>` | see above (there is no `widgetViz`; use `widget viz <style>`) |
| `importShader <text>` | import a shadertoy link or GLSL as a style |

## Daemon HTTP API

`127.0.0.1:47837`, loopback only. It refuses cross-site and DNS-rebinding requests (and `Origin: null`),
so a web page you visit cannot drive it.

- playback: `GET /status` (long-polling), `POST /play`, `/enqueue`, `/control/{action}`, `/quality`, `/sleep`, `/quit`
- library: `GET /search`, `/collection/{what}`, `/liked`, `/queue?from=&count=` (a window of the play order), `/lyrics/{id}`, `/stats`; `POST /favorite`
- sign-in: `POST /login/link`, `/login/pkce/start`, `/login/pkce/finish`, `/logout`
- EQ: `GET|POST /eq`, `POST /eq/presets`, `DELETE /eq/presets/{id}`, `GET /autoeq/search?q=`, `POST /autoeq/apply`, `/autoeq/clear`, `/autoeq/refresh`
- drop map and shaders: `GET /analysis/{id}`, `GET /shaders`, `POST /shaders/import`, `/shaders/reload`
- video: `GET /yt/search`, `POST /yt/play`, `GET /anime/search`, `/anime/episodes`, `POST /anime/watch`, `/anime/curd`, `/video/{action}`
- scrobbling and remote: `GET /scrobble`, `POST /scrobble/flush`, `/lastfm/auth/start`, `/lastfm/auth/finish`, `/lastfm/disconnect`, `GET /remote/pair`, `POST /remote/pair/reset`

The phone remote has its own pairing-gated listener on the LAN (`/remote`, `/remote/api/*`), off by default.
