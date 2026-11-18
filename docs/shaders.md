# Shaders

## Your own

Any Shadertoy-style `.frag` in your shader folder becomes a style called `@<file name>`:

| | |
|---|---|
| Linux | `~/.config/orpheus/shaders` (`$XDG_CONFIG_HOME`) |
| Windows | `%LOCALAPPDATA%\Orpheus\shaders` |
| either | `ORPHEUS_SHADERS` overrides it |

Save a file there and it compiles in a second or two (qsb, one at a time, idle priority). Edit it while
it is on screen and it rebuilds in place. A broken save keeps the last good picture and says which line:
in a toast, a tick on the stage, settings ▸ visuals ▸ your shaders, and `.build/<name>.log`.

Other ways in:

- paste a shadertoy link or an Image shader's code into `Ctrl+K`; it offers "import shader · …" first
- drop a `.frag` on the visualizer card (on Linux that depends on the compositor; the palette always works)
- `omarchy-shell orpheus importShader <text>`

**What works.** `mainImage`, `iTime`, `iResolution`, `iMouse` (xy, hover), `iFrame`, `iTimeDelta`.
`iChannel0` is the audio (512x2: a spectrum row, plus a wave synthesised from the 32 bands; Orpheus
never sees samples), `iChannel1` the spectrum history. Every Orpheus uniform is in scope too (`band(x)`,
`kick`, `beatPhase`, `build`, `drop`, `pal(x)`), and the folder's `README.txt` lists them.

**Pragmas.** `//! name:`, `//! scale:` (default 0.8), `//! time: flow`, `//! transition:`. A line
`//#common` makes it an Orpheus-native shader.

**Limits.** Only Image + Common passes; multipass shaders get a clear no. No album art ever reaches a shader.

**Shadertoy links** need your own app key (settings ▸ integrations ▸ shadertoy, or `shadertoyKey` in
config.json) and a shader published as Public + API. Imports keep the author and link at the top of the
file (Shadertoy's default licence is CC BY-NC-SA 3.0).

**Windows** needs the compiler: put `qsb.exe` and `Qt6ShaderTools.dll` in
`%LOCALAPPDATA%\Orpheus\tools\qsb`, or set `ORPHEUS_QSB`.

## Rebuilding the built-in ones

`shaders/*.frag` compile to `.qsb` with `build-shaders.sh`, which inlines `shaders/_common.glsl` at each
`//#common` line and runs `qsb --qt6`. The compiled `.qsb` files are committed, so a normal install
does not need this. It takes file names to build only some.

`qsb` ships with Qt 6's shader tools. On Arch it is in `qt6-shadertools` and installs to
`/usr/lib/qt6/bin/qsb`, which is **not on `PATH`**. The script falls back to that path itself; anywhere
else, set `QSB`:

```sh
./build-shaders.sh
QSB=/path/to/qsb ./build-shaders.sh
```

The std140 uniform block in `_common.glsl` must match `Viz.qml` exactly, or the visualizer renders black.
