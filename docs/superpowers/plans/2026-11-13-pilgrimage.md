# Pilgrimage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A stage mode where the song travels through a route of shader styles by section, each boundary crossed with a timed morph that lands on the boundary itself.

**Architecture:** Approach A from the spec: the Director gains three section-ahead outputs; a pure `Pilgrim.js` library holds the route logic; a `Pilgrimage.qml` QtObject drives the stage style with a landing time and a transition kind; Viz's existing two-style transition path does the morph, with a new "veil" kind in trans.frag. UI hooks ride the existing flag plumbing.

**Tech Stack:** QML (Quickshell/Qt 6), GLSL (`qsb`-packaged), Python unittest + PySide6 for headless QML/JS tests.

**Spec:** `docs/superpowers/specs/2026-11-01-pilgrimage-design.md` (read it first; its §1 findings carry the file:line map and its final "Decisions" section resolves all open questions).

## Global Constraints

- Nothing new is `recursive: true`, and no recursive ShaderEffectSource ever changes `textureSize` in place (Viz.qml:314-317, VizPost.qml:102-110).
- The user `//! transition:` pragma range stays 0..4 (orpheusd/shaders.py:104-105 unchanged). Veil (kind 5) is Pilgrimage's own.
- Section codes: 0 intro, 1 build, 2 drop, 3 breakdown, 4 steady (Director.qml:70-71).
- The same song always gives the same journey: rotation seeded by track id (spec Decision 4).
- The widget and rail keep the home style: Pilgrimage changes `Stage.current` only, never `config.style`.
- Tests run with `uv run --with pytest python -m pytest tests/ -q` (desktop extra synced). All existing tests keep passing.
- `trans.frag.qsb` is rebuilt with the venv's `pyside6-qsb` on Linux; it will lack DXBC until the author reruns build-shaders.sh on Windows (test_dxbc.py skips off-Windows). Say so in the commit message.
- The spec §6 offscreen GPU tools (shader_preview.py, viz_stress.py, shader_seq.py) are not in this repo; the GPU budget and stress runs are out of scope here. The headless suite is the gate.

## Review Focus

Spec-implied inputs no task's happy path exercises; each line's test is added to the owning task.

1. A malformed `pilgrimRoute` (a string, a number, lists holding non-strings) must resolve to the defaults, never throw — Task 2.
2. `beatPeriod` 0 (no grid at all) through `timing()` must give finite ms (2000), never NaN — Task 2.
3. A map whose `sections` is empty or missing, with pilgrimage on, must fall back to the live path without a request storm — Task 6.
4. The style list shrinking mid-song (style removed) while that style is the leg on screen must skip to the next leg, not freeze — Task 6.
5. A boundary arriving with `nextSecIn` under 0.3 s must not hand Viz a sub-300 ms `landMs` (Viz ignores it; the boundary is skipped) — Task 6.

---

### Task 1: Director section-ahead outputs

**Files:**
- Modify: `Director.qml` (outputs ~line 80; `onMapChanged` ~line 418; `mapTick` ~line 509)
- Test: `tests/test_director_qml.py`

**Interfaces:**
- Produces: `property int secIdx` (index of the current mapped section, −1 while the map is untrusted), `property real nextSecIn` (seconds of presented time to the next section boundary, −1 none), `property int nextSecCode` (that section's code, −1 none). Each written only when it changes, like `dropIn`.

- [ ] **Step 1: Write the failing tests.** Extend the `basic()` wrapper scenario to sample the three new outputs, and extend `regression()`/`nullMap()`:

```python
# in test_follows_the_map, from new fields captured by basic():
#   out.sec at t≈6 (tl in section 0): {"idx": 0, "nin": ~6.0, "code": 1}
self.assertEqual(r["sec6"]["idx"], 0)
self.assertAlmostEqual(r["sec6"]["nin"], 12 - r["sec6"]["tl"], delta=0.02)
self.assertEqual(r["sec6"]["code"], 1)
#   at t≈20 (inside build): idx 1, code 2, nin counts to 28
self.assertEqual(r["sec20"]["idx"], 1)
self.assertEqual(r["sec20"]["code"], 2)
#   past the last boundary (t≈50): nextSecIn -1, nextSecCode -1
self.assertEqual(r["secEnd"], {"idx": 3, "nin": -1, "code": -1})

def test_untrusted_map_hides_sections_ahead(self):
    # extends regression(): with confidence 0.3 the three outputs stay -1 throughout
    r = self.run_js("regression")
    self.assertEqual(r["secIdx"], -1)
    self.assertEqual(r["nextSecIn"], -1)
    self.assertEqual(r["nextSecCode"], -1)
```

In the WRAPPER, `basic()` records `sec6`/`sec20`/`secEnd` as `{idx: d.secIdx, nin: d.nextSecIn, code: d.nextSecCode, tl: tl}` when `|t − 6| < 0.009` etc.; `regression()` tracks the max of each output over the run.

- [ ] **Step 2: Run to verify failure.** `uv run --with pytest python -m pytest tests/test_director_qml.py -q` — FAIL (undefined properties read as undefined → assertions fail).
- [ ] **Step 3: Implement.** Declare the three outputs (defaults −1) beside `dropMapped`. Reset all three to −1 in `onMapChanged` and in the `!B` early-return of `mapTick`. In `mapTick`, after the cursor walk, when `mapOn`: `secIdx = si − 1` (clamp ≥ −1), `nextSecIn = si < secStart.length ? secStart[si] − tl : −1`, `nextSecCode = si < secCode.length ? secCode[si] : −1`; when `!mapOn`, all −1. Guard each write with an inequality check as the neighbors do.
- [ ] **Step 4: Run to verify pass.** Same command — all director tests PASS.
- [ ] **Step 5: Commit.** `git add Director.qml tests/test_director_qml.py && git commit -m "director: expose the next mapped section boundary (secIdx, nextSecIn, nextSecCode)"`

### Task 2: Pilgrim.js route logic

**Files:**
- Create: `Pilgrim.js` (`.pragma library`, pure functions, no QML imports)
- Test: `tests/test_pilgrim_js.py` (QJSEngine harness copied from tests/test_tui_js.py)

**Interfaces:**
- Produces:
  - `DEFAULT_ROUTE = { intro: ["@cathedral"], build: ["@organ"], drop: ["abyss", "@descent", "@mandelbox"], breakdown: ["@drowned", "@kleinian"], steady: ["@cathedral", "@rosewindow"] }`
  - `FALLBACK = { intro: "aurora", build: "tunnel", drop: "abyss", breakdown: "aurora", steady: "horizon" }`
  - `CODES = ["intro", "build", "drop", "breakdown", "steady"]`
  - `seedOf(trackId) -> int` — deterministic non-negative hash of the id string ("" → 0).
  - `resolve(route, styles) -> object` — DEFAULT_ROUTE overlaid with the config route's own keys, every list filtered to names in `styles`; a list left empty becomes `[FALLBACK[kind]]`. Any malformed input (non-object route, non-array list, non-string entries) is ignored at that key.
  - `ordinals(sections) -> array<int>` — for each section, its occurrence number within its code (`sections` is the map's `[{start,end,code}]`; null/empty → `[]`).
  - `leg(resolved, code, ordinal, current, banned, seed) -> string` — entry `(seedOf-seed + ordinal) mod len` of the code's list, skipping entries in `banned` (unless all are banned) and skipping `current` when the list has another entry; a one-entry list returns that entry even when it is `current`.
  - `timing(code, beatPeriod, mapped) -> {ms, kind}` — `bar = beatPeriod > 0 ? 4000 * beatPeriod : 0`. Drop (code 2): `ms = bar ? clamp(bar, 1200, 2500) : 2000`, `kind = 1`. Others, mapped: `ms = bar ? clamp(2 * bar, 800, 4000) : 2000`; unmapped: `ms = bar ? clamp(bar, 800, 4000) : 2000`. Kind: 4 (melt) for breakdown (code 3), 5 (veil) for intro/build/steady.

- [ ] **Step 1: Write the failing tests** in `tests/test_pilgrim_js.py`, loading `Pilgrim.js` the way test_tui_js.py loads Tui.js:

```python
def test_resolve_filters_and_falls_back(self):
    r = self.ev('JSON.stringify(resolve(null, ["abyss","@organ","aurora","tunnel","horizon"]))')
    r = json.loads(r)
    self.assertEqual(r["drop"], ["abyss"])          # @descent/@mandelbox missing -> filtered
    self.assertEqual(r["build"], ["@organ"])
    self.assertEqual(r["breakdown"], ["aurora"])    # list emptied -> fallback
    self.assertEqual(r["intro"], ["aurora"])

def test_resolve_ignores_malformed_route(self):
    base = 'resolve(%s, ["abyss","aurora","tunnel","horizon"])'
    for bad in ('"x"', '42', '{drop: "abyss"}', '{drop: [1, {}]}'):
        r = json.loads(self.ev('JSON.stringify(' + base % bad + ')'))
        self.assertEqual(r["drop"], ["abyss"])      # defaults, not a throw

def test_ordinals(self):
    secs = '[{code:4},{code:1},{code:2},{code:4},{code:2}]'
    self.assertEqual(self.ev('JSON.stringify(ordinals(%s))' % secs), '[0,0,0,1,1]')

def test_leg_rotates_and_never_repeats_current(self):
    res = '({drop:["a","b","c"]})'
    self.assertEqual(self.ev('leg(%s, 2, 0, "", [], 0)' % res), "a")
    self.assertEqual(self.ev('leg(%s, 2, 1, "", [], 0)' % res), "b")
    self.assertEqual(self.ev('leg(%s, 2, 0, "a", [], 0)' % res), "b")   # skips current
    self.assertEqual(self.ev('leg(%s, 2, 0, "a", ["b"], 0)' % res), "c")  # and banned
    self.assertEqual(self.ev('leg(({drop:["a"]}), 2, 3, "a", [], 0)'), "a")  # single entry stays
    self.assertEqual(self.ev('leg(%s, 2, 0, "", ["a","b","c"], 0)' % res), "a")  # all banned: list kept

def test_leg_seed_shifts_rotation(self):
    res = '({drop:["a","b","c"]})'
    self.assertEqual(self.ev('leg(%s, 2, 0, "", [], 1)' % res), "b")
    self.assertNotEqual(self.ev('seedOf("12345")'), self.ev('seedOf("12346")'))

def test_timing_clamps(self):
    for bpm, dropMs, buildMs in ((70, 2500, 4000), (128, 1875, 3750), (174, 1379, 2759)):
        t = json.loads(self.ev('JSON.stringify(timing(2, %s, true))' % (60.0 / bpm)))
        self.assertAlmostEqual(t["ms"], dropMs, delta=1); self.assertEqual(t["kind"], 1)
        t = json.loads(self.ev('JSON.stringify(timing(1, %s, true))' % (60.0 / bpm)))
        self.assertAlmostEqual(t["ms"], buildMs, delta=1); self.assertEqual(t["kind"], 5)
    t = json.loads(self.ev('JSON.stringify(timing(3, 0, false))'))
    self.assertEqual(t, {"ms": 2000, "kind": 4})     # no grid: finite, melt for breakdowns
    t = json.loads(self.ev('JSON.stringify(timing(4, 60/128, false))'))
    self.assertAlmostEqual(t["ms"], 1875, delta=1)   # unmapped: one bar
```

- [ ] **Step 2: Run to verify failure.** `uv run --with pytest python -m pytest tests/test_pilgrim_js.py -q` — FAIL (file missing).
- [ ] **Step 3: Implement `Pilgrim.js`** per the Produces block. `seedOf`: a simple 31-multiplier string hash folded to a non-negative int.
- [ ] **Step 4: Run to verify pass.**
- [ ] **Step 5: Commit.** `git commit -m "pilgrimage: route logic as a pure library (Pilgrim.js)"`

### Task 3: Viz morph inputs and the oldSrc scale fix

**Files:**
- Modify: `Viz.qml` (requestStyle ~line 394, beginTransition ~line 416, oldSrc ~line 508)

**Interfaces:**
- Produces on Viz: `property real landMs: -1` (300..5000 ms: begin at once, land in that long; else ignored), `property real morphMs: -1` (300..5000: duration used by a normal downbeat-gated transition), `property int morphKind: -1` (≥ 0 overrides `tkind`). Consumed by Task 5 (StageView pass-through) and Task 7.

- [ ] **Step 1: Implement.** In `requestStyle`, after `pendingStyle = styleName` and before the `mapLocked` stretch: `if (landMs >= 300 && landMs <= 5000) { beginTransition(Math.round(landMs)); return }`. In `beginTransition`: `tkind = morphKind >= 0 ? Math.min(5, morphKind) : <existing choice>`; duration line becomes `transAnim.duration = durationMs > 0 ? durationMs : (morphMs >= 300 && morphMs <= 5000 ? Math.round(morphMs) : <existing formula>)`. Add `readonly property real oldUserScale: oldMeta && oldMeta.scale > 0 ? oldMeta.scale : 1` beside `userScale`, and change `oldSrc.textureSize` to `Qt.size(Math.max(1, Math.round(width * dpr * renderScale * oldUserScale)), Math.max(1, Math.round(height * dpr * renderScale * oldUserScale)))` (safe: `oldSrc` is not recursive).
- [ ] **Step 2: Verify.** `uv run --with pytest python -m pytest tests/ -q` — all pass (test_qml_ids.py parses the changed file; no behavior test reaches Viz headless).
- [ ] **Step 3: Commit.** `git commit -m "viz: timed-landing and kind overrides for morphs; shade the outgoing style at its own scale"`

### Task 4: VizPost trail-buffer base and StageView plumbing

**Files:**
- Modify: `VizPost.qml` (fbWant ~line 111), `Viz.qml` (postComponent ~line 95), `StageView.qml` (vizLoader ~line 84, sample() ~line 149)

**Interfaces:**
- Produces: `VizPost.fbBase` (size; when width > 0 it replaces `sourceSize` in `fbWant`, so style changes with different `//! scale:` no longer rebuild the trail buffer). StageView properties `landMs`, `morphMs`, `morphKind` (reals/int, default −1, forwarded to Viz) and `readonly property bool morphing` (the loaded Viz's `transitioning`, else false). Consumed by Task 7.

- [ ] **Step 1: Implement VizPost.** `property size fbBase: Qt.size(0, 0)`; `fbWant` derives from `fbBase.width > 0 ? fbBase : sourceSize`. In Viz's `postComponent`, set `fbBase: Qt.size(Math.max(1, Math.round(fx.width * fx.dpr * fx.renderScale)), Math.max(1, Math.round(fx.height * fx.dpr * fx.renderScale)))`. The Loader rebuild mechanism stays untouched.
- [ ] **Step 2: Implement StageView.** Add the three pass-through properties on `view`, bind them in the `sourceComponent: Viz` block; add `readonly property bool morphing: vizLoader.item ? vizLoader.item.transitioning === true : false`. In `sample()`, count a slow second only when not morphing: `if (fps < target * 0.85) { if (!morphing) low++; good = 0 }`.
- [ ] **Step 3: Verify.** Full suite passes.
- [ ] **Step 4: Commit.** `git commit -m "vizpost: trail buffer keyed to render scale, not style scale; stageview: morph pass-through, auto quality ignores morphs"`

### Task 5: trans.frag kind 5 "veil"

**Files:**
- Modify: `shaders/trans.frag`, rebuild `shaders/trans.frag.qsb`

- [ ] **Step 1: Implement the veil branch.** Insert `else if (kind > 4.5) { ... }` BEFORE the existing `kind > 3.5` melt branch (melt would otherwise swallow 5). The look, from the spec: a luminance-keyed crossfade — key `0.6 * luma(tap(b, ub)) + 0.4 * fbm(uv * asp * 3.0 + seed)`; a threshold sweeping 1 → 0 with `p` (the incoming world's bright structure emerges first through the old world's darks); the old view drifting outward (zoom 1 → 1.05 about the center) while the new settles in (0.96 → 1); a faint palette edge (`lightUp` with `mix(c1.rgb, c2.rgb, …)`) along the threshold, faded at both ends with `mid`. 2–3 taps and one fbm per pixel.
- [ ] **Step 2: Rebuild the package.** `./.venv/bin/pyside6-qsb --qt6 -o shaders/trans.frag.qsb shaders/trans.frag` (trans.frag has no `//#common` include). Verify it loads: `./.venv/bin/pyside6-qsb -d shaders/trans.frag.qsb | head` prints the shader description.
- [ ] **Step 3: Verify.** Full suite passes (test_dxbc.py skips off-Windows).
- [ ] **Step 4: Commit** with a body noting the `.qsb` was built on Linux and needs a Windows build-shaders.sh pass to bake DXBC: `git commit -m "trans: kind 5 veil, a luminance-keyed crossfade for long morphs"`

### Task 6: Pilgrimage.qml driver

**Files:**
- Create: `Pilgrimage.qml` (QtQml `QtObject`, imports `"Pilgrim.js" as Pilgrim`)
- Test: `tests/test_pilgrimage_qml.py` (wrapper pattern and canned MAP copied from tests/test_director_qml.py; the wrapper instantiates a Director fed by the MAP and a Pilgrimage bound to its outputs, stepping both on the fake clock)

**Interfaces:**
- Consumes: Director outputs from Task 1; `Pilgrim.*` from Task 2.
- Produces (Stage binds these in Task 7):
  - Inputs: `enabled` (bool), `styles` (var), `route` (var, config.pilgrimRoute or null), `map` (var, the drop map or null), `mapLocked` (bool), `secIdx`/`nextSecIn`/`nextSecCode` (the Director's), `sectionCode` (int, live), `beatPeriod` (real, s per beat, 0 = no grid), `transitioning` (bool), `hidden` (bool), `director` (bool), `trackId` (string).
  - Outputs: `style` (string, "" until the first request), `landMs` (real, −1), `morphMs` (real, −1), `kind` (int, −1). **Order on every request: kind, morphMs, landMs first, `style` last** (QML bindings propagate synchronously, so a consumer bound to both sees the timing before the name).
  - Methods: `tick(ms)` (the clock; drives dwell and the director-off walk), `skip() -> string` (morph at once, over one bar, to the next entry for the current section's kind; returns the leg name or ""), `detour(name)` (hold `name` until the next section boundary, then resume), `reset()` (track change), `ban(name)` (session ban; skips at once if `name` is on screen).

- Rules (from spec §2/§4, all tested below):
  - Mapped (`mapLocked` and `nextSecCode ≥ 0`): when `nextSecIn ≤ timing(nextSecCode, beatPeriod, true).ms / 1000` and `nextSecIn ≥ 0.3`, arm once per boundary (key: `secIdx + 1`), skip if `transitioning`, skip if the entered section is shorter than 4 bars (from `map.sections`) unless it is a drop, skip while less than 1 bar into the current section. Request: `landMs = nextSecIn * 1000`.
  - Live (map untrusted/absent): on `sectionCode` change, with a 16 s dwell since the last request: `landMs = −1`, `morphMs = timing(..., false).ms`. Live ordinals come from a per-track counter per code.
  - Director off: `tick` walks the steady list every 40 s.
  - Hidden: no requests; on unhide, one request for the current section's leg with `landMs = −1`.
  - The seed is `Pilgrim.seedOf(trackId)`; `reset()` clears armed keys, counters, and detour (not the ban list — it is per session).

- [ ] **Step 1: Write the failing tests.** Scenarios in the wrapper, assertions in Python:

```python
def test_build_leg_requested_two_bars_early(self):
    r = self.run_js("mapped")          # MAP: steady 0-12, build 12-28, drop 28-44, steady 44-60; 120 BPM, bar = 2 s
    # build boundary at 12: lead = min(2 bars, 4 s) = 4 s -> requested near t = 8
    self.assertAlmostEqual(r["build"]["t"], 8.0, delta=0.1)
    self.assertAlmostEqual(r["build"]["landMs"], 4000, delta=120)
    self.assertEqual(r["build"]["kind"], 5)
    self.assertEqual(r["build"]["style"], "@organ")

def test_drop_leg_lands_on_the_drop(self):
    r = self.run_js("mapped")          # drop lead = clamp(1 bar, 1.2, 2.5) = 2 s -> requested near t = 26
    self.assertAlmostEqual(r["drop"]["t"] + r["drop"]["landMs"] / 1000, 28.0, delta=0.05)
    self.assertEqual(r["drop"]["kind"], 1)

def test_timing_lands_before_style(self):
    # the wrapper records landMs/kind AT the moment style changes
    r = self.run_js("mapped")
    self.assertEqual(r["drop"]["landAtStyle"], r["drop"]["landMs"])

def test_short_section_keeps_the_style(self):
    r = self.run_js("shortSection")    # a 6 s (3-bar) steady slice between builds: no request for it
    self.assertEqual(r["requests"], r["requestsWithout"])

def test_boundary_inside_a_morph_is_skipped(self):
    r = self.run_js("morphBlocks")     # transitioning=true across the build boundary: no request, and none after
    self.assertEqual(r["requests"], 0)

def test_live_mode_dwell(self):
    r = self.run_js("live")            # no map: request on sectionCode change with landMs -1 and morphMs set;
    self.assertEqual(r["first"]["landMs"], -1)
    self.assertGreater(r["first"]["morphMs"], 0)
    self.assertEqual(r["flaps"], 1)    # a second change 5 s later is held by the 16 s dwell

def test_hidden_holds_and_return_requests_once(self):
    r = self.run_js("hiddenReturn")
    self.assertEqual(r["whileHidden"], 0)
    self.assertEqual(r["onReturn"], 1)

def test_skip_and_detour(self):
    r = self.run_js("manual")
    self.assertNotEqual(r["skipTo"], "")             # skip() returned the new leg
    self.assertEqual(r["duringDetour"], r["picked"]) # style holds the picked name until the boundary
    self.assertNotEqual(r["afterBoundary"], r["picked"])  # then the route resumes

def test_gpu_ban_skips_at_once(self):
    r = self.run_js("banned")          # ban(current leg) -> style changes immediately, never returns to it
    self.assertNotEqual(r["after"], r["bannedName"])
    self.assertEqual(r["cameBack"], 0)

def test_empty_sections_falls_back_to_live(self):
    r = self.run_js("noSections")      # map with sections: [] stays quiet on the mapped path; live changes still work
    self.assertEqual(r["mappedRequests"], 0)

def test_sub_300ms_boundary_skipped(self):
    r = self.run_js("lateArm")         # driver first sees the boundary with nextSecIn < 0.3: no landMs under 300
    self.assertEqual(r["under300"], 0)

def test_removed_style_on_screen_skips(self):
    r = self.run_js("removedLeg")      # styles list shrinks under the current leg via ban("removed-style")
    self.assertNotEqual(r["after"], r["removed"])
```

The wrapper gives Pilgrimage a fake styles list `["abyss","aurora","tunnel","horizon","prism","@organ","@cathedral","@descent","@mandelbox","@drowned","@kleinian","@rosewindow"]`, `trackId: "1"`, and steps `tick` at 16 ms alongside the Director.

- [ ] **Step 2: Run to verify failure.** `uv run --with pytest python -m pytest tests/test_pilgrimage_qml.py -q` — FAIL (Pilgrimage.qml missing).
- [ ] **Step 3: Implement `Pilgrimage.qml`** per the Produces block. Internal state: `armedIdx` (last boundary key), `lastLegAt` (ms), `detourIdx` (−1 none), `ordCount` (per-code live counters), `banned` ([]), `resolved` (recomputed on `styles`/`route` change — when the list changes, re-resolve; the leg on screen stays unless banned/removed). Mapped arming reacts to `nextSecIn` changes; live to `sectionCode` changes; both funnel through one `request(name, land, morph, k)` that writes outputs in the pinned order and stamps `lastLegAt`.
- [ ] **Step 4: Run to verify pass.** Whole suite: `uv run --with pytest python -m pytest tests/ -q`.
- [ ] **Step 5: Commit.** `git commit -m "pilgrimage: the driver — a song travels between styles by section"`

### Task 7: Stage integration

**Files:**
- Modify: `Stage.qml` (style block ~line 87, autoStyle Connections ~line 111, switchOnDrop ~line 120, handleKey ~line 186, tabs Repeater ~line 428, both StageView sites ~lines 280 and 478)

**Interfaces:**
- Consumes: `Pilgrimage` (Task 6), StageView properties (Task 4), Service properties from Task 8 (`engine.pilgrimage`, `engine.pilgrimRoute`, `engine.secIdx`, `engine.nextSecIn`, `engine.nextSecCode`, `engine.dropMapData`, `engine.pilgrimageSkips`, `engine.setStageFlag("pilgrimage", …)`). Write this task after Task 8, or stub nothing: the properties all exist once Task 8 lands — order Tasks 8 before 7 at execution time if preferred; they touch disjoint files.

- [ ] **Step 1: Instantiate the driver** in Stage.qml:

```qml
property Pilgrimage pilgrim: Pilgrimage {
  enabled: !!win.engine && win.engine.pilgrimage === true
  styles: win.engine ? win.engine.styles : []
  route: win.engine ? win.engine.pilgrimRoute : null
  map: win.engine ? win.engine.dropMapData : null
  mapLocked: !!win.engine && win.engine.mapLocked
  secIdx: win.engine ? win.engine.secIdx : -1
  nextSecIn: win.engine ? win.engine.nextSecIn : -1
  nextSecCode: win.engine ? win.engine.nextSecCode : -1
  sectionCode: win.engine ? win.engine.sectionCode : 4
  beatPeriod: win.engine && win.engine.beatConfidence > 0.35 ? 60 / Math.max(40, win.engine.paceBpm) : 0
  transitioning: win.bleed ? (showView.item ? showView.item.morphing : false) : (cardView.item ? cardView.item.morphing : false)
  hidden: !win.visible
  director: !!win.engine && win.engine.director
  trackId: win.engine && win.engine.api && win.engine.api.track ? String(win.engine.api.track.id) : ""
}
```

plus a 250 ms Timer (`running: pilgrim.enabled && win.visible`) calling `pilgrim.tick(Date.now())`, a Connections on `engine.shaderEvent` calling `pilgrim.ban("@" + name)` for kinds `gpu` and `removed`, and one on `engine.pilgrimageSkipsChanged` → `var nm = pilgrim.skip(); if (nm) picked(engine.styleLabels[nm] || nm)`.
- [ ] **Step 2: Route the style.** `current` becomes `engine ? (engine.pilgrimage && pilgrim.style ? pilgrim.style : (engine.autoStyle && liveStyle ? liveStyle : engine.style)) : "skyline"`. Both StageView sites bind `landMs: win.engine && win.engine.pilgrimage ? win.pilgrim.landMs : -1`, likewise `morphMs: … win.pilgrim.morphMs : -1` and `morphKind: … win.pilgrim.kind : -1` (the driver's output is named `kind`; StageView's property is `morphKind`). `pick(name)`: when `engine.pilgrimage`, call `pilgrim.detour(name); picked(engine.styleLabels[name] || name); return` before the `setStyle` path (the home style stays). `switchOnDrop()` returns at once when `engine.pilgrimage` (autoStyle is ignored while pilgrimage is on).
- [ ] **Step 3: Keys and tab.** In `handleKey`, before the digit rows: `g` → `engine.setStageFlag("pilgrimage", "toggle"); picked(engine.pilgrimage ? "pilgrimage" : "pilgrimage off")` (read after the toggle lands — flip the label logic accordingly) and `n` → the skip call from Step 1 (only while `engine.pilgrimage`; otherwise fall through to `return false`). After the tabs `Repeater`, add a `~ pilgrimage` Text styled like the tab delegates (bracketed/bold when `engine.pilgrimage`, MouseArea toggles the flag, TuiTip key "g").
- [ ] **Step 4: Verify.** Full suite (test_qml_ids.py checks the new ids). `git commit -m "stage: pilgrimage mode — tab, keys, detours, autoStyle handoff"`

### Task 8: Service, settings, palette, keys sheet, README

**Files:**
- Modify: `Service.qml` (defaults ~line 81, flag properties ~line 108, Director block ~line 783, setStageFlag ~line 958, statusText ~line 1039, IpcHandler ~line 1067), `SettingsPane.qml` (rows after autoStyle ~line 492, flag list in setValue ~line 471), `CommandPalette.qml` (flags ~line 179), `KeysSheet.qml` (~line 42), `README.md` (§07 keybinds table, §02 feature list)

**Interfaces:**
- Produces (consumed by Task 7): `readonly property bool pilgrimage: config.pilgrimage === true`; `readonly property var pilgrimRoute: config.pilgrimRoute && typeof config.pilgrimRoute === "object" ? config.pilgrimRoute : null`; `readonly property var dropMapData: dropMapSrc.map`; pass-throughs `secIdx`/`nextSecIn`/`nextSecCode` from `directorCore`; `property int pilgrimageSkips: 0` and `function nextLeg() { pilgrimageSkips++; return statusText() }`.

- [ ] **Step 1: Service.** Add `pilgrimage: false` to `defaults`; the properties above; `"pilgrimage"` in `setStageFlag`'s keys; `pilgrimage: pilgrimage` in `statusText`; IPC `function pilgrimage(on: string): string { return root.setStageFlag("pilgrimage", on) }` and `function pilgrimNext(): string { return root.nextLeg() }`.
- [ ] **Step 2: SettingsPane.** After the autoStyle row: `r.push({ kind: "toggle", id: "pilgrimage", label: "pilgrimage", def: d.pilgrimage, desc: "travel between styles with the song" })`; a `note` row listing route styles missing from `e.styles` (import `"Pilgrim.js" as Pilgrim`, resolve the configured route's names against the list, join the absent ones; no row when none missing). Add `"pilgrimage"` to the flag array in `setValue`.
- [ ] **Step 3: Palette and keys sheet.** CommandPalette flags array += `["pilgrimage", "toggle pilgrimage"]`; while `e.pilgrimage`, `add("viz.pilgrimage.next", "visuals", "pilgrimage · next leg", "n", "", function() { e.nextLeg() })`. KeysSheet "in the visualizer window" += `["g", "pilgrimage on / off"]`, `["n", "next leg · pilgrimage"]`.
- [ ] **Step 4: README.** One row in the §07 key table for `g`/`n`, one feature bullet in §02 ("pilgrimage — the song travels between styles by section, morphing on the boundaries").
- [ ] **Step 5: Verify.** Full suite. `git commit -m "pilgrimage: flag, route config, IPC, settings row, palette, keys"`

### Task 9: Whole-branch verification

- [ ] **Step 1:** `uv run --with pytest python -m pytest tests/ -q` — everything passes.
- [ ] **Step 2:** Re-read the spec's §2 behaviour list and Decisions 1–7 against the diff (`git diff main --stat` + each file); fix anything missed.
- [ ] **Step 3:** Request a code review of the branch (superpowers:requesting-code-review) and resolve findings.

## Execution notes

- Task order: 1 → 2 → 3 → 4 → 5 → 6 → 8 → 7 → 9 (7 reads properties 8 creates; everything else is independent after 1+2).
- Not runnable here (needs the author's machine): the §6 GPU budget table, viz_stress/morph montages, and the live mapped-track watch. The honest list in the README does not change for them.
