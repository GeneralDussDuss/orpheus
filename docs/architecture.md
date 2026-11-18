# How it fits together

Two halves that talk over a loopback socket.

```
 TIDAL · Navidrome · SoundCloud · YouTube
                     │
                 ┌───▼──────────────────────┐        ┌──────────────────────┐
                 │  orpheusd  (Python)      │  JSON  │  Quickshell plugin   │
                 │                          │◄──────►│  (QML + GLSL)        │
                 │  · tidalapi session      │  :47837│                      │
                 │  · mpv over JSON IPC     │        │  · Library / Visualizer   │
                 │  · MPRIS over dbus-next  │        │  · Widget / BarWidget│
                 │  · queue + resume.json   │        │  · 20 style shaders  │
                 └───┬──────────────────────┘        └──────────▲───────────┘
                     │                                          │
                    mpv ──► PipeWire ──────────► cava ──────────┘
                                                 32 bands @ 30/60 Hz
```

- **`orpheusd/`**, the daemon. `tidal.py` owns the session and the catalogue, `navidrome.py` is a
  Subsonic client, `youtube.py` / `soundcloud.py` go through `yt-dlp`. `player.py` drives `mpv` over its
  JSON IPC (launched `--load-scripts=no`, so mpv's own MPRIS script stays out of the way);
  `mpris.py` publishes the standard interface. `dropmap.py` maps a
  track's beats, bars, builds and drops ahead of time (numpy, ffmpeg at idle). It serves the
  [HTTP API](config.md#daemon-http-api) on `127.0.0.1:47837`.
- **`*.qml`**, the shell plugin. `Service.qml` is the always-on half: it runs `cava`, detects beats,
  reads theme colours live and registers the IPC handler. `Library.qml` is the player window,
  `Stage.qml` the fullscreen one, `Widget*.qml` the desktop widget (`DeckCore.qml` is the shared
  brains of the vertical decks), `BarWidget.qml` the bar spectrum, `Viz.qml` the shader host.
- **`shaders/`**, the GLSL. `_common.glsl` is inlined at each `//#common` line by `build-shaders.sh`;
  `history.frag` is a feedback pass that keeps a 32×40 spectrum history on the GPU, so Prism and Horizon
  can build terrain out of the past. `mini` is a small style for bar-sized surfaces.

## Tempo

The shaders never read the clock. They read a distance the CPU integrates from the current tempo, so
when the pace changes, the world's speed changes with it.

Tempo is estimated by autocorrelating the spectral-flux envelope at a fixed 50 Hz. The octave is chosen
against a target derived from onset density, with a veto on any candidate that would imply more than
3.5 onsets per beat. That is what stops a dense breakbeat locking to half-time.

The visualizer follows the song's sections (intro, build, drop, breakdown, steady): style changes land on
the downbeat with a transition, and it can switch style when a drop lands. When drop detection knows a
track, it follows the map instead: the picture winds up over the last bars, blacks out on the last
beat and bursts on the drop, drop marks show on the seek bar, and each style-journey morph lands on the
section boundary itself.
