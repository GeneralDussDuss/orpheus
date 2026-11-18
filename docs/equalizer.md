# Equalizer and headphone corrections

Open it with `e` in the player, or `omarchy-shell orpheus eq` to open the window straight onto it.
Keys are in [keys.md](keys.md#panes).

## The ten bands

31, 62, 125, 250, 500 Hz and 1, 2, 4, 8, 16 kHz, ±12 dB in half-decibel steps. The two end bands are
shelves rather than peaks, because a peaking filter at 31 Hz with Q 1.4 has almost no effect by 20 Hz.
"Lift the sub-bass" should do what it says.

It runs inside mpv as a filter chain, not as a PipeWire sink. So it follows the output device on its
own, affects nothing but Orpheus, and adds no dependency. **A flat or disabled EQ removes the filter
entirely**: the signal path is untouched rather than running through a unity-gain biquad.

Six tone presets ship with it: Flat, Bass Lift, Vocal, Loudness, Tame Treble and Speech.

The transport bar carries a small readout beside the volume: eight block glyphs summarising the ten
bands, accented while a filter is live and a flat dim line when not, so you can tell at a glance
whether something is shaping the sound. Left click opens the pane, right click bypasses.

### Headroom, and why a boost can sound quieter

Boosting a band cannot make anything louder; there is nothing above full scale. So the preamp pulls
the whole signal down by the size of the largest boost. Lift 31 Hz by 6 dB and the bass lands at net
zero while everything else drops 6. Relative to each other the bass is +6; absolutely, the track got
quieter. That is what stops it clipping, and it matters here because mpv runs with
`--replaygain-clip=no`, so material is allowed above 0 dBFS before the EQ touches it.

You can take the headroom back: `[` and `]` move the preamp half a decibel at a time, `\` returns it to
automatic. Taking less than the curve needs is allowed, and says **may clip** while it is.

```sh
curl -s 127.0.0.1:47837/eq                                   # bands, presets, current state
curl -X POST 127.0.0.1:47837/eq -d '{"preset":"loudness","enabled":true}'
curl -X POST 127.0.0.1:47837/eq -d '{"band":0,"gain":4.5}'   # one band, for a slider
curl -X POST 127.0.0.1:47837/eq -d '{"enabled":false}'       # bypass
```

## Headphone corrections (AutoEQ)

Orpheus ships **no measurement data**, on purpose. The obvious source is
[AutoEq](https://github.com/jaakkopasanen/AutoEq), whose MIT licence covers its code and not its data:
the measurements come from oratory1990, Rtings, Super Review and others, none of whom have granted
redistribution, and the maintainer confirms the distinction in AutoEq issue
[#790](https://github.com/jaakkopasanen/AutoEq/issues/790). So Orpheus ships the importer instead, and
the numbers stay on your machine.

**The picker.** On the equalizer page press `A`, type a model (`hd600`, `sundara`, `moondrop aria`)
and press ⏎. Orpheus looks it up in AutoEq's public index, downloads that one headphone's
`ParametricEQ.txt` to your machine, and plays through it. Rows name the measurement source and rig
(oratory1990, crinacle on 711, Rtings…), oratory1990 first where there is a choice, as AutoEq itself
recommends; `●` marks the one in use. Everything is credited to its source and fetched only when you ask.

**Stacked, not swapped.** The correction runs first, in the same mpv filter graph, and your ten bands
sit on top of it, so the bars now mean "on top of my headphones". Its curve is drawn beneath the bars
on the same scale, with the combined response dashed over it. With a correction live, the automatic
preamp is measured from the combined response (the top of the whole cascade, rounded up to half a
decibel), so it is exactly enough headroom and no more. `x` switches the correction off without
forgetting it, `X` forgets it, and presets (`>` `<`) leave it alone.

**Caching.** The index (about 9,000 headphones) is fetched on the first search and refreshed in the
background once a month (`ctrl+r` in the picker refreshes it now); devices are fetched once. Both live
in `~/.cache/orpheus/autoeq` (Linux) or `%LOCALAPPDATA%\Orpheus\cache\autoeq` (Windows). The chosen
correction is stored with the EQ state in `daemon.json`, so it keeps playing after a restart with the
network unplugged. Offline with no index, the picker lists the headphones you have used before.

```sh
curl -s '127.0.0.1:47837/autoeq/search?q=hd%20600'
curl -X POST 127.0.0.1:47837/autoeq/apply -d '{"path":"oratory1990/over-ear/Sennheiser HD 600"}'
curl -X POST 127.0.0.1:47837/eq -d '{"autoeqOn":false}'      # off, kept
curl -X POST 127.0.0.1:47837/autoeq/clear                    # forgotten
```

### By hand, from a fixed-band file

Find your headphones in AutoEq's results and take the **`FixedBandEQ.txt`** (not `ParametricEQ.txt` or
`GraphicEQ.txt`: the fixed-band file is already fitted to these exact ten centres), then post it:

```sh
curl -X POST 127.0.0.1:47837/eq/presets -H 'Content-Type: application/json' \
  -d "{\"name\":\"Sennheiser HD 6XX\",\"text\":$(jq -Rs . < 'Sennheiser HD 6XX FixedBandEQ.txt')}"
```

It lands in `~/.local/state/orpheus/eq-presets.json` and appears beside the tone presets.
`DELETE /eq/presets/{id}` removes one.

The importer will warn you about one thing: AutoEq fits out to 20 kHz, above the range where coupler
measurements are reliable, so the 16 kHz band often comes out as a large cut that is an artefact of
the fit rather than anything you would hear. The warning is advisory; your data is imported as written.
