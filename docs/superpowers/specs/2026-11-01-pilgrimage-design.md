# Pilgrimage: a song as a journey through styles

Date: 2026-11-01 · Branch: `viz-expansion` · Status: design, awaiting review

Pilgrimage is a stage mode. Instead of holding one style, the stage moves through a
route of styles as the song moves through its sections. For example, the intro
plays in Cathedral of Folds, the build in The Organ, the drop dives into Abyss and
the breakdown drifts into the Drowned Cathedral. At each boundary the two styles
morph into each other instead of cutting. With a drop map, each morph lands on the
boundary itself, including the drop frame.

## 1. What exists today (findings)

**Style choice and switching**
- `Service.styles` is the builtins plus every user style that has a build, written
  as `"@" + name` (Service.qml:33-47). `styleUrl()` resolves builtins beside the app
  and user styles to the daemon's content-hashed `.qsb` (Service.qml:69-71).
  `userStyle()` returns the daemon's metadata (`uses`, `scale`, `transition`)
  (Service.qml:61-65; shaders.py:320-323).
- The stage's style is `Stage.current`: `engine.autoStyle && liveStyle ? liveStyle :
  engine.style` (Stage.qml:91-92). autoStyle changes the stage only. Config, the
  widget and the rail keep the chosen style. A manual pick clears `liveStyle`
  (Stage.qml:97-101). `engine.style` also feeds the widget (`syncViz`,
  Service.qml:135), the cassette's ambient view (Cassette.qml:358) and the
  library's ambient view (Library.qml:840).
- autoStyle lives in **Stage.qml, not Director.qml**. It switches on
  `onDropsChanged`. It also pre-arms 1.5 s early on `armedDrop`, so the transition
  lands on a mapped drop. It picks a random other style with a 20 s cooldown
  (Stage.qml:111-127).

**Transitions** (Viz.qml:369-508, VizPost.qml:72-93, shaders/trans.frag)
- A change of `styleName` waits for the next downbeat when `beatConfidence > 0.35`,
  for at most 2.5 s (Viz.qml:386-407). Then `oldFx` renders the outgoing style live
  next to `fx`, and `trans.frag` blends the two over `tprog`.
- Duration: normally 0.8 to 1.5 s by tempo (Viz.qml:422). When `mapLocked` and
  `0.3 < dropIn < 3`, the transition is **stretched to `dropIn`** so it completes on
  the drop frame (Viz.qml:396).
- Kinds: 0 slices, 1 zoom through, 2 radial dissolve, 3 chroma, 4 melt
  (trans.frag:3-9). The kind comes from the builtin table `kinds`
  (Viz.qml:383), then from the user style's `//! transition:` (clamped to 0..4,
  shaders.py:103-105), then at random (Viz.qml:417-419). All six pack styles
  declare `transition: 1`.
- A new request during a transition calls `endTransition()` first, so the
  in-flight blend **snaps** (Viz.qml:412).
- The feedback profile already blends across the transition (Viz.qml:84-86).

**What the drop map knows ahead of time**
- The worker computes beats, bars, drops (with strength and kind), builds, and
  **sections as `{start, end, code}` runs over the whole track**, all on the song
  clock (dropmap.py:401-461; section codes from dropmap.py:354-382). Runs shorter
  than 2 bars are merged, except builds and drops.
- Only TIDAL tracks of known length up to 20 min are analysed. Other providers,
  live streams and long tracks are skipped (analysis.py:125-143). The worker runs
  ahead for the current and next track (analysis.py:1-13).
- `DropMapSource` fetches the map, so the Director has every section boundary
  **ahead of time** (DropMapSource.qml:23-37).
- The Director caches `secStart` and `secCode` (Director.qml:426-430) and walks a
  cursor `si` (Director.qml:466-474). While it trusts the map (`mapOn`: confidence
  at least 0.5, playing, and the live grid agrees, Director.qml:464, 498-507), the
  section follows the map (Director.qml:374, 515). Only drops are exposed ahead of
  time (`dropIn`, `armedDrop`, `anticipate`, Director.qml:523-532). **Nothing
  exposes the next section boundary yet.** That is the one Director addition this
  feature needs.
- Without the map, sections come from the live detector and are entered only
  after being wanted for 1 to 2 bars (Director.qml:35-36, 626-641). A morph then
  starts after the boundary, not before it.

**Cost model**
- Two styles already render together during every transition. `oldFx` draws into
  the non-recursive `oldSrc` at `fx.layer.textureSize` (Viz.qml:438-508). So a
  morph is the existing double-raymarch, only longer: up to about 4 s instead of
  0.8 to 1.5 s. After `transFx`, the post chain (feedback, show, bloom) runs once,
  not twice (VizPost.qml:6-8, 93).
- **Gotcha 1:** `oldSrc.textureSize` uses the *incoming* style's `effScale`
  (Viz.qml:46, 507). A user style at scale 0.65 leaving for builtin Abyss (scale
  1.0) is shaded at about 2.4 times its normal pixel count for the whole morph.
  That is harmless for 1 s, but it is the worst case of a 4 s morph.
- **Gotcha 2:** the feedback buffer size comes from `sourceSize` (the layer size,
  which includes `userScale`) (Viz.qml:91; VizPost.qml:111-120). So every switch
  between styles with different `//! scale:` rebuilds the trail buffer in its
  Loader. That is crash-safe and done by design (VizPost.qml:103-110), but trails
  blink off for at least 150 ms, right at the morph and so right at the drop.
- Auto quality steps down after 3 slow seconds (StageView.qml:108-175). A 4 s
  morph that dips frames could trigger it on every boundary.
- Hard rules:
  - A `recursive: true` ShaderEffectSource never changes `textureSize` in place;
    rebuild it in a Loader instead (VizPost.qml:103-157, Viz.qml:307-365).
    `oldSrc` and `transSrc` are not recursive.
  - Every `.qsb` carries DXBC: build-shaders.sh:15 bakes it, and
    tests/test_dxbc.py checks it.
- **No GPU numbers were taken for this spec.** Deadlock was running, and GPU
  renders wait for it to close. The first plan task measures them (§6).

**Where the UI hooks go**
- Flags go through `setStageFlag` (Service.qml:953-959). Settings rows sit under
  "follow the music" (SettingsPane.qml:126-134), and their flag list is at
  SettingsPane.qml:471.
- The palette's flag list is at CommandPalette.qml:179-181, and its style entries
  at CommandPalette.qml:131-135.
- The stage tabs are a Repeater over `engine.styles` (Stage.qml:428-446). Stage
  keys are in `handleKey` (Stage.qml:186-206), and the key sheet's stage block is
  at KeysSheet.qml:40-42.
- `g` and `n` are free on the stage.
- Game mode hides the Stage window (Stage.qml:64).

## 2. User-facing behaviour

**Turning it on.** Pilgrimage is a stage mode, not a style. A pseudo-style named
`pilgrimage` in `styles` would leak to the widget (`syncViz`), the rail and both
ambient views, which would all need a resolver. As a mode, it works like autoStyle:
- It changes the stage only. `config.style` stays the home style for the widget
  and the rail.
- It is reached from:
  - a settings toggle: **"pilgrimage · travel between styles with the song"**
  - the palette: "toggle pilgrimage" and "pilgrimage · next leg"
  - a last stage tab, `~ pilgrimage`, which is bracketed when on and toggles on
    click
  - stage keys: **`g`** toggles it, **`n`** skips to the next leg
  - IPC: `pilgrimage on|off|toggle`
- When pilgrimage is on, autoStyle is ignored. The tab of the leg on screen shows
  as current, as usual.

**The route.** Each section kind maps to an ordered list of styles. The *n*-th
occurrence of a kind in the song takes entry `n mod len`. The journey is
deterministic: the same song gives the same pilgrimage, and a seek back replays it.
When the next leg would be the style already on screen, the next entry is taken.
When a kind's list has only that style, the stage stays on it.

Default route:

| section | styles (in order) |
|---|---|
| intro | `@cathedral` |
| build | `@organ` |
| drop | `abyss`, `@descent`, `@mandelbox` |
| breakdown | `@drowned`, `@kleinian` |
| steady | `@cathedral`, `@rosewindow` |

- **Editing:** `config.json` key `pilgrimRoute`, with the same shape, keyed by
  section name. No route editor in v1. Settings shows one note row listing the
  route styles that are missing.
- **Missing styles** are dropped from their list. A list left empty falls back to
  one builtin per kind:

  | section | fallback |
  |---|---|
  | intro | aurora |
  | build | tunnel |
  | drop | abyss |
  | breakdown | aurora |
  | steady | horizon |

  This keeps pilgrimage working before pack 2 is installed.

**How morphs are timed.** With a trusted map (`mapLocked`), each morph *ends on the
boundary*:

| entering | lands | length | transition |
|---|---|---|---|
| drop | the drop frame | 1 bar, clamped to 1.2–2.5 s | 1 zoom through (the dive) |
| build | the boundary | 2 bars, at most 4 s | 5 veil (new) |
| breakdown, steady, intro | the boundary | 2 bars, at most 4 s | 5 veil |

- A morph never starts earlier than 1 bar after the current section began.
- A section shorter than 4 bars keeps the current style, unless it is a drop.

**Without a map, or with low confidence.** This covers state `none`, `failed` or
`pending`, a non-TIDAL track, `mapConf < 0.5`, the live grid disagreeing, and
`dropMap` off.
- Pilgrimage follows the live `sectionCode` changes and requests the leg on the
  change.
- Viz's existing downbeat wait applies: it waits for the next downbeat when
  `beatConfidence > 0.35`, and goes at once otherwise.
- The morph lasts 1 bar, or 2 s when there is no grid.
- A minimum dwell of 16 s stops a nervous detector from thrashing.
- With the director off, there are no sections at all. Pilgrimage then walks the
  steady list every 40 s.

**Manual control.**
- `n` (or the palette's "next leg") morphs at once, over 1 bar, to the next entry
  for the current section's kind, and shows a VizLabel with the leg's name.
- A manual pick while pilgrimage is on (a tab, the arrows, the digits) is a
  **detour**. The picked style holds until the next section boundary, and then
  the route resumes. Turning pilgrimage off goes back to `engine.style`.
- Leg changes are otherwise silent: no label, so the journey reads as one piece.

## 3. Approaches

**A. Switching at the app level, on the existing transition path, with a morph
timing hint (recommended).** A small driver picks the leg from the section and the
route, and sets the stage style a measured lead before the boundary. It hands Viz a
duration and a kind. Viz's existing `oldFx` → `transFx` path does the morph.
- Cost: two raymarchers only inside the morph window (at most 4 s per boundary,
  about 4 to 8 times per song). Otherwise one, as today.
- Reuse: nearly everything. The downbeat wait, the stretch to the drop, the
  feedback profile blend, user-style loading and error reporting all stay.
- Linux parity: pure QML and JS, plus one new GLSL branch in trans.frag, built by
  build-shaders.sh on both platforms.
- Limit: a morph is a 2D blend of two finished frames, not a geometric morph.

**B. A dedicated morph pass over two persistent Viz decks.** Two full Viz
instances (A/B) with their own VizPost, plus a Morph.qml compositor that warps
between them and can hold "between worlds" for a whole section.
- Most flexible.
- Costs double the post chain and double the VRAM (RGBA16F layer, trail buffer and
  bloom pyramid per deck). The history and ink passes are also duplicated.
- The uniform plumbing that `oldFx` carries (Viz.qml:435-499) would be duplicated
  again.
- Two persistent decks means two raymarchers always, unless they are loaded on
  demand, at which point it becomes A with more parts.

**C. One mega-shader.** All the SDFs in one `.frag`, smooth-min blended under a
shared camera.
- The only true geometric morph.
- But a blended SDF evaluates both fields on every step, so it costs no less than
  A during a morph and much more otherwise.
- It cannot include user styles, which are separate Shadertoy files with their
  own cameras and materials. All six pack styles plus Cathedral and Abyss would
  have to be rewritten into one file.
- Compile time, DXBC size and register pressure all grow, and live editing of a
  single style is lost.

**Recommendation: A.** The transition machinery already does 90% of a morph,
including landing on a mapped drop. What it lacks is a section-ahead signal, a
duration and kind override, a morph-friendly blend, and two cost fixes, all small
and all useful beyond Pilgrimage. B and C pay a large, permanent cost for a better
look in the morph window, which is a few seconds per boundary.

## 4. Design (approach A)

### Components

1. **Director.qml: three outputs**, computed in `mapTick` next to `dropIn`, and
   only while `mapOn` (otherwise −1):
   - `secIdx`: the index of the current mapped section, `si − 1`.
   - `nextSecIn`: seconds of presented time to `secStart[si]`.
   - `nextSecCode`: `secCode[si]`.

   Each is written only when it changes, like `dropIn`.
2. **Pilgrim.js** (new, `.pragma library`, pure):
   - `DEFAULT_ROUTE` and `FALLBACK`
   - `resolve(route, styles)` → the route with missing styles filtered and
     fallbacks applied
   - `ordinals(sections)` → for each section, its occurrence number within its
     kind
   - `leg(resolved, code, ordinal, current, banned)` → a style name
   - `timing(code, beatPeriod, mapped)` → `{ms, kind}`, with the clamps from §2
3. **Pilgrimage.qml** (new, a QtQml `QtObject` like Director, so it is testable on
   a fake clock):
   - Inputs: `enabled`, `styles`, `route`, `map`, `mapLocked`, `secIdx`,
     `nextSecIn`, `nextSecCode`, `sectionCode`, `beatPeriod`, `transitioning`,
     `hidden`, `director`, and the clock via `tick(ms)`.
   - Outputs: `style`, `landMs` and `kind`.
   - Methods: `skip()`, `detour(name)` and `reset()` (on a track change).
   - Rules:
     - Arm once per boundary, keyed by the boundary's song time, as
       `armedDrop` is.
     - Never request while `transitioning`. A boundary that falls inside a morph
       is skipped.
     - Keep a session ban list fed by `engine.shaderEvent` kinds `gpu` and
       `removed`. A banned style on screen is skipped at once.
4. **Viz.qml**: two inputs and one cost fix.
   - `landMs` (−1 = none): in `requestStyle`, when `300 ≤ landMs ≤ 5000`, call
     `beginTransition(landMs)` instead of waiting for a downbeat. This sits
     beside the existing `dropIn` stretch, which stays for autoStyle.
   - `morphKind` (−1 = none): when 0 or more, `beginTransition` uses it for
     `tkind`, overriding `kinds` and the pragma.
   - The `oldSrc.textureSize` fix: shade the outgoing style at its *own* scale,
     `width·dpr·renderScale·oldUserScale`. This is safe because `oldSrc` is not
     recursive.
5. **VizPost.qml**: size the trail buffer from a `fbBase` that Viz passes in,
   `width·dpr·renderScale`, without `userScale`. The trail buffer then rebuilds
   only on a resize or a render-scale step, never on a style change. The Loader
   rebuild stays exactly as it is.
6. **trans.frag: kind 5 "veil"**, a luminance-keyed crossfade for long morphs.
   - The incoming world's bright structure (its lights, rose windows, organ
     pipes) emerges first through the old world's darks.
   - A threshold sweeps 1 → 0 with `prog`, keyed on 0.6·luma(b) + 0.4·fbm.
   - The old view drifts outward (zoom 1 → 1.05) while the new one settles
     (0.96 → 1).
   - A faint palette edge is drawn on the threshold.
   - It needs 2 or 3 taps and a 4-octave fbm per pixel at layer resolution,
     which is negligible next to a raymarch.
   - The existing kinds are tuned for about 1 s: slices stretched to 4 s read as
     a broken cut. Zoom stays for drops.
   - The `.qsb` is rebuilt with build-shaders.sh on Windows, so it carries DXBC.
   - The user pragma range stays 0..4. Veil is Pilgrimage's.
7. **StageView.qml**:
   - Pass `landMs` and `morphKind` through to Viz.
   - Auto quality does not count slow seconds while `vizLoader.item.transitioning`.
     A morph's dip then never moves the resolution and so never rebuilds the trail
     buffer mid-morph.
8. **Stage.qml**:
   - Instantiate `Pilgrimage`, with `hidden: !win.visible || engine.gameMode`.
   - Change `current` to: `pilgrimage && pilgrim.style ? pilgrim.style :
     (autoStyle && liveStyle ? liveStyle : engine.style)`.
   - `pick()` calls `pilgrim.detour(name)` while pilgrimage is on.
   - Add keys `g` and `n`, and the `~ pilgrimage` tab after the Repeater.
   - Suppress autoStyle's `switchOnDrop` while pilgrimage is on.
9. **Service.qml**:
   - Config keys `pilgrimage` (bool, default false) and `pilgrimRoute` (object,
     default absent).
   - Add `"pilgrimage"` to the `setStageFlag` keys, an IPC
     `pilgrimage(on)`, and pass-throughs for the Director's three new outputs.
   - **SettingsPane.qml**: a toggle row after autoStyle, the missing-styles note,
     and the flag list at :471.
   - **CommandPalette.qml**: a flag entry, plus "pilgrimage · next leg" while on.
   - **KeysSheet.qml**: `g` and `n`.

### Data flow

```
dropmap.py ──/analysis──▶ DropMapSource.map ──▶ Director (secStart/secCode, mapOn)
                                                  │ secIdx, nextSecIn, nextSecCode, sectionCode
                                                  ▼
Service.styles, pilgrimRoute ──▶ Pilgrimage.tick(ms) ── Pilgrim.js (resolve, leg, timing)
                                                  │ style, landMs, kind   (set landMs/kind FIRST)
                                                  ▼
Stage.current ──▶ StageView ──▶ Viz.styleName / landMs / morphKind
                                                  ▼
            requestStyle → beginTransition(landMs) → oldFx+fx → transFx(kind) → feedback → show → bloom
```

**Mapped boundary.** The drop map's `nextSecIn` falls to the lead for the next
code, and the arm key changes. Pilgrimage then sets `landMs = nextSecIn·1000` and
`kind`, and only after that sets `style`.

QML bindings propagate synchronously, so Viz sees `landMs` before
`onStyleNameChanged` fires. A test asserts this order.

**Live boundary.** `sectionCode` changes and the dwell has passed. Pilgrimage sets
`landMs = −1` and `kind = 5`, then `style`. Viz's downbeat wait does the rest.

### Error handling

- **Style missing or not built:** user styles without a build never enter `styles`
  (Service.qml:44-47), so `resolve` drops them. When the style list changes, the
  route is resolved again. The leg on screen stays unless it was removed.
- **Compile failure on an edit:** the daemon keeps the last good build
  (shaders.py:8-10). Nothing to do here.
- **GPU-side failure** (`ShaderEffect.Error`, Viz.qml:33-34 →
  `shaderEvent("gpu")`, Service.qml:358-361): the style is banned for the session,
  and if it is on screen, the stage skips to the next leg.
- **Game mode, or the stage hidden:**
  - While hidden, nothing is requested. The driver stays cheap, a few
    comparisons per tick.
  - On return, it requests the current section's leg with `landMs = −1`. Viz cuts
    when it is not visible (Viz.qml:389-390) and otherwise uses a normal downbeat
    transition.
- **Seeks:** the Director's cursors re-search (Director.qml:467-468). `secIdx`
  jumps, the leg is recomputed from the new index, and the ordinal is
  deterministic. Nothing is armed retroactively.
- **Track change:** `reset()`, then live mode until the new map is ready. The
  intro leg is requested at the first downbeat.
- **Back-to-back short sections:** skipped while a morph is in flight, so
  `endTransition` never snaps a morph (Viz.qml:412).
- **The crash rule:** nothing new is recursive.
  - The trail buffer keeps its Loader rebuild, and change 5 makes those rebuilds
    rarer.
  - `oldSrc` and `transSrc` may change size safely.
  - A `viz_stress.py` run covers this (§6).

## 5. Out of scope (YAGNI)

- A route editor UI.
- Per-leg transition choices in the route.
- Geometric (SDF) morphs.
- Routing the widget, the rail or the ambient views.
- Routes for each genre or track.
- Extending the user `//! transition:` range to 5.
- Shuffled journeys.

## 6. Testing

**Headless unittest** (the existing patterns):
- `tests/test_pilgrim_js.py`, in a QJSEngine like tests/test_tui_js.py:
  - `resolve` with missing styles and an empty list going to the fallback
  - `ordinals` on a repeating map
  - `leg` rotation, never repeating the current style, and the ban list
  - `timing` clamps at 70, 128 and 174 BPM
- `tests/test_pilgrimage_qml.py`, QtQml on a fake clock like
  tests/test_director_qml.py:1-45, reusing its canned `MAP` (steady 0–12, build
  12–28, drop 28–44, steady 44–60):
  - The build leg is requested at about 12 s minus 2 bars, with `landMs` ≈ the
    lead.
  - The drop leg lands within one frame of 28.0 s, with kind 1.
  - A section under 4 bars is ignored.
  - Without the map, the request comes after `sectionCode` changes, with
    `landMs = −1`, and the 16 s dwell holds.
  - While hidden, nothing is requested; on return, one request.
  - `skip()` and `detour()` do what §2 says.
  - A `gpu` event bans the style.
  - `landMs` is visible to a bound consumer before `style` changes.
- `tests/test_director_qml.py`: `secIdx`, `nextSecIn` and `nextSecCode` follow the
  map, and are −1 when the map is untrusted. This extends
  `test_untrusted_map_changes_nothing` (:224).
- The existing guards keep running: tests/test_dxbc.py (trans.frag.qsb is rebuilt
  with DXBC) and tests/test_qml_ids.py (no new id shadows a property).

**Offscreen GPU checks** (the local offscreen render tools: `shader_preview.py`, `rcgrab.py`, `viz_stress.py`). These run **only when
`deadlock.exe` is not running**.
- `shader_preview.py <style> out.png bigsize=2752x1152`, for Cathedral, every pack
  style and Abyss. The median frame time of each goes into a table in the plan.
- **Budget:** the most expensive adjacent pair of legs must fit in 12 ms at
  bigsize (60 fps with headroom for post). A pair that does not fit gets a lower
  `//! scale:` in that style's file, not a code change.
- `shader_seq.py ... to=<style> at=<frame>`:
  - Extend it with `kind=` and `ms=`, and with user styles (`styleUrl` and
    `userStyle` on its fake engine, building through `shaders.translate` and qsb
    as shader_preview does).
  - Use it to render a veil montage (Cathedral → Organ) and a zoom-to-drop
    montage (Organ → Abyss) for review.
- `viz_stress.py`:
  - Extend it with the same user-style support and a `morph=` option (random
    `landMs` 300–4000, kinds 1 and 5).
  - Run 400 switches with `scales=0.2 resize=0.1 rt=1`, with bloom and feedback
    on. Pass means no crash, and the trail buffer rebuilds only on scale or
    resize lines.
- **Live:** one mapped EDM track at fullscreen, watching the journey and that the
  drop lands on the frame. Then one unmapped track, which should stay calm with no
  thrash.

## 7. Open questions

1. Is the default route right? Should the drop leg rotate Abyss → Infinite Descent
   → Mandelbox Nave, or always dive into Abyss?
2. Drowned Cathedral and Mandelbox Nave are not staged yet (pack2 has only
   descent, kleinian, organ and rosewindow). Will their files be `drowned.frag` and
   `mandelbox.frag`, so the slugs are `@drowned` and `@mandelbox`?
3. Is editing the route in config.json enough for v1, or do you want a route
   editor in settings?
4. Should every play of a song give the same journey (proposed), or a fresh
   rotation each time?
5. While pilgrimage is on, should the widget and the rail follow the leg, or keep
   the home style (proposed, as autoStyle does)?
6. The morph look: veil for every non-drop boundary and zoom for drops? Or melt
   for breakdowns ("drifts into the Drowned Cathedral")?
7. A manual pick while pilgrimage is on: a detour until the next boundary
   (proposed), or should it turn pilgrimage off?

## Decisions (2026-11-01)

The user delegated the open questions ("figure it out"):

1. Default route: drops rotate (Abyss, Infinite Descent, Mandelbox Nave); breakdowns Drowned Cathedral or Kleinian Caverns; steady Cathedral of Folds or Rose Window; build The Organ; intro Cathedral of Folds. The cavern family (Geode, Lumen Grotto, Obsidian Void) is also installed and may join the breakdown and steady legs.
2. Pack files are `drowned.frag` and `mandelbox.frag` (installed).
3. v1 route editing is `config.json` only.
4. The same song always gives the same journey (route seeded by track id).
5. The widget and rail keep the home style.
6. Veil for non-drop boundaries, zoom into drops, melt into breakdowns.
7. A manual pick is a detour until the next section boundary.
