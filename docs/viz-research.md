# Viz research: "infinite fire" tier reactive shaders

Distilled from two research passes (2026-11-05): shadertoy fire/volumetric technique, and
audio→shader mapping (MilkDrop/cava/butterchurn lineage). Audio-side claims about
MilkDrop/cava math were web-verified; shader-side reference IDs are from memory — verify
a Shadertoy ID before citing it anywhere public.

## Technique tiers, by payoff per GPU dollar (single-pass, GLSL ES 3.0 friendly)

1. **Domain-warped FBM** (iq's "warping"): `q = fbm(p)`, `r = fbm(p + 4q + t)`,
   `f = fbm(p + 4r)`. The best fire/plasma/nebula per cycle; 60fps at 1080p on an iGPU.
   For fire: stretch y, scroll noise upward, ragged vertical falloff mask.
2. **Cosine palettes** (`a + b*cos(6.28*(c*t+d))`): near-free, multiplies everything else.
   Four vec3s per palette — can be derived from the Omarchy theme and crossfaded with a
   plain mix. Fire ramp without a palette: `vec3(1.5f, 1.5f³, f⁶)`.
3. **Kaliset fields**: `p = abs(p)/dot(p,p) - c` looped 20-40×, accumulate glow. Nebula /
   fractal-flame look. Audio drives `c` by ±0.02 max — it's chaotic, more teleports.
   Guard `dot(p,p)` with `max(…, 1e-4)`.
4. **Single-pass fluid fake**: iterated warp `p += cos(p.yzx*f + t)/f` (XorDev turbulence
   loop) or stacked rotated sines. Liquid-fire look, cheap.
5. **Raymarched volumetric fire/nebula** (nimitz "Protean Clouds" tier): the flagship
   look. 24-40 steps × 3-4 FBM octaves, per-pixel jitter on ray start (kills banding,
   best quality/cost trade there is), render-scale knob mandatory — our auto-quality
   stepper already exists in StageView.
6. **Feedback buffer tier** (phase 2): one ping-pong `prev = tex(uv + flow*dt)*0.98`
   gives smoke trails/afterglow single-pass can't. We already do GPU feedback in
   history.frag, so the plumbing exists. Real fluid / reaction-diffusion = many passes,
   only if a style demands it.

## GLSL hygiene (hard-won list)

- `precision highp float;` always — ES 3.0 fragment shaders have NO default.
- Hash: Dave Hoskins fract-hash, never `fract(sin(dot)*43758)`.
- `tanh` overflows to NaN on some drivers: clamp input to ±10 or use `x/(1+abs(x))`.
  A single NaN persists forever in a feedback buffer — `max(c, 0.)` before writes.
- `pow(negative, y)` is NaN → `pow(max(x,0.), y)`.
- Rotate the domain between FBM octaves (kills axis-aligned artifacts).
- Dither dark gradients: `+(hash(frag)-.5)/255.` — banding killer, free.
- Tonemap (`1-exp(-c)`) before gamma.
- House rule already in CLAUDE.md and it matches the research exactly: shaders read
  `flow` (CPU-integrated distance), never `time * speed`. The research's phrasing:
  "integrate, don't multiply" — `phase += dt*(base + k*energy)` on CPU.

## Audio → parameter mapping (the "alive vs wiggly" difference)

Pipeline: FFT → log bands → EQ tilt (raw FFT starves treble) → dB compress →
AGC (slow reference `ref = max(v, ref*0.9995)`, floored, so quiet tracks still move;
freeze gain in silence so hiss doesn't dance) → per-band attack/release envelopes.

| signal | drives | envelope |
|---|---|---|
| kick impulse (onset × exp decay ~150ms) | scale pulse, displacement, zoom kick, bloom bump | attack 5-20ms, release 150-300ms |
| mid | warp strength, turbulence, body | 20-40ms / 200-400ms |
| treble | sparkle, grain, fine octave gain, edge glow | 5-10ms / 80-150ms |
| slow energy (0.5-1s / 1-2s) | speed (via flow), rotation, bloom threshold | the mood channel |
| bass/bass_att ratio (MilkDrop) | "is it spiking" accent, free beat signal | fast/damped pair |
| spectral centroid | hue drift | ~1s smoothing |

Principles:
- **One primary driver per visual parameter.** Everything sharing one signal = mush.
- **Two timescales**: fast (hits) + slow (section/mood). Section change = short energy
  avg (1s) vs long (10s) ratio → rare, big moves (palette step, mode shift).
- **Idle life**: silence must breathe (~0.1Hz), audio modulates, never gates.
- **Kick as damped spring** (overshoot + settle), not bare exponential.
- Palette steps on every Nth strong onset, eased over ~300ms — never snap per onset.
- dt-based smoothing constants (times, not per-frame factors) — cava's `framerate_mod`,
  MilkDrop's `pow(r, 30/fps)`.
- **Flash safety**: cap full-field luminance change rate; WCAG 2.3.1 = max 3 flashes/s.
  Prefer scale/warp/hue to full-screen brightness hits.

Orpheus-specific: cava weights bars by frequency — bass peaks ~0.15 while mids hit ~0.45
(CLAUDE.md, measured). Any new style tunes against OUR bass scale, not MilkDrop's 1.0
conventions. The engine already computes energy/bass/beat/travel/flow and drop maps
(armedDrop pre-arms 1.5s ahead) — that drop map is a signal MilkDrop never had: a
visualizer that *knows the drop is coming* can wind up before it lands. Nobody else has
that. Use it.

## References worth studying (verify IDs before citing)
iq: Warping article + Palettes shader; nimitz: Protean Clouds, Plasma Globe; Kali:
Star Nest; TDM: Seascape; Silexars: Creation; XorDev: turbulence/tanh family; Shane:
lighting craft. Audio side: MilkDrop preset authoring guide (geisswerks.com — canonical
bass/bass_att semantics), cava `cavacore.c` (gravity fall, autosens), butterchurn
`audioLevels.js`, projectM `beat_detect.cpp`.

## Proposed build order
1. `_common.glsl` additions: Hoskins hash, FBM w/ rotation, cosine palette, safe-tanh,
   dither — shared by every new style.
2. **Inferno** — domain-warped fire, bass→flame height, mid→warp, drop map→pre-arm swell.
3. **Nebula** — kaliset + theme-derived palette, centroid→hue drift.
4. **Ink** — turbulence-loop liquid, the cheap stunner.
5. **Volume** — the flagship jittered raymarch, auto-quality aware.
6. Feedback-trail post pass (history.frag pattern) as an opt-in layer.
