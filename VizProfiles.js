.pragma library

// Feedback profiles, one per style: how last frame's picture moves, fades and
// recolours under this one (VizPost.qml / shaders/feedback.frag). Per-frame
// numbers at 60 fps; warp() rescales them for the real frame rate.
//
//   zoom      > 1 pushes the old picture outward from (cx, cy) every frame
//   zoomK/S   extra push on kicks / with the loudness
//   rot       turn per frame (radians); rotK on kicks
//   swirl     extra turn at the centre, falling off outward; swirlK on kicks
//   ripple    radial wave bending the picture in and out; rippleK on kicks
//   dx, dy    drift per frame in uv (+dy = up)
//   turb      curling smoke flow
//   smear     radial streaking toward the centre (hyperspace); smearK on kicks
//   decay     linear light kept per frame at "full"; "subtle" squares it
//   shift     pull toward the palette per frame
//   gain      how strongly the trails show
//   cx, cy    the centre, in uv (y down)
var base = { zoom: 1, zoomK: 0, zoomS: 0, rot: 0, rotK: 0, swirl: 0, swirlK: 0, ripple: 0, rippleK: 0,
             dx: 0, dy: 0, turb: 0, smear: 0, smearK: 0, decay: 0.94, shift: 0.02, gain: 0.8, cx: 0.5, cy: 0.5 }

var styles = {
  // The sun's heat: the sky glow breathes outward from the sun and shimmers up.
  prism:   { zoom: 1.003, zoomK: 0.010, zoomS: 0.003, dy: 0.0006, turb: 0.0005, decay: 0.93, shift: 0.06, gain: 0.8, cx: 0.56, cy: 0.24 },
  // Smoke off the stage: column tops and caps leave haze rising into the lights.
  skyline: { zoom: 1.0015, zoomK: 0.004, dy: 0.0022, turb: 0.0011, decay: 0.94, shift: 0.06, gain: 0.85, cx: 0.5, cy: 0.75 },
  // The land rolls toward you, so its light does too, out of the sun.
  horizon: { zoom: 1.005, zoomK: 0.012, zoomS: 0.004, dy: -0.0004, decay: 0.93, shift: 0.06, gain: 0.8, cx: 0.5, cy: 0.42 },
  // A plasma vortex: the orb's light spirals out around it.
  orb:     { zoom: 1.006, zoomK: 0.018, rot: 0.003, swirl: 0.03, swirlK: 0.07, decay: 0.935, shift: 0.07, gain: 0.95, cx: 0.5, cy: 0.46 },
  // Infinite: every ring echoes on outward past the camera.
  tunnel:  { zoom: 1.014, zoomK: 0.03, zoomS: 0.006, rot: 0.004, rotK: 0.012, decay: 0.92, shift: 0.06, gain: 1.0, cx: 0.5, cy: 0.5 },
  // The kick waves ripple outward through the field.
  halo:    { zoom: 1.006, zoomK: 0.016, rot: -0.002, ripple: 0.004, rippleK: 0.014, decay: 0.915, shift: 0.08, gain: 0.95, cx: 0.5, cy: 0.5 },
  // Smoke trails: the beam leaves a curling wisp rising off it.
  scope:   { zoom: 1.0, dy: 0.0018, turb: 0.0022, decay: 0.95, shift: 0.06, gain: 0.95, cx: 0.5, cy: 0.5 },
  // The dive: the lit creases and lantern stream back past the camera, a little harder on kicks.
  abyss:   { zoom: 1.008, zoomK: 0.02, zoomS: 0.004, decay: 0.90, shift: 0.05, gain: 0.7, cx: 0.5, cy: 0.5 },
  // Hyperspace: stars smear into long streaks, hardest on kicks.
  nova:    { zoom: 1.012, zoomK: 0.04, zoomS: 0.008, smear: 0.006, smearK: 0.03, decay: 0.915, shift: 0.07, gain: 0.9, cx: 0.5, cy: 0.5 },
  // Gravitational waves: each kick's ripple echoes outward through the trails, a faint swirl around the lens.
  lens:    { zoom: 1.002, zoomK: 0.006, swirl: 0.012, swirlK: 0.03, ripple: 0.003, rippleK: 0.012, decay: 0.925, shift: 0.06, gain: 0.8, cx: 0.5, cy: 0.5 },
  // Buttery wake: the lit folds stream gently back past the camera and curl.
  gyre:    { zoom: 1.005, zoomK: 0.012, zoomS: 0.003, rot: 0.0012, turb: 0.0008, decay: 0.93, shift: 0.05, gain: 0.75, cx: 0.5, cy: 0.5 },
  // Slow drifting dust: very soft zoom and curl, long trails.
  nebula:  { zoom: 1.0006, zoomK: 0.002, turb: 0.0006, decay: 0.965, shift: 0.03, gain: 0.6, cx: 0.5, cy: 0.5 },
  // Heat haze: smoke rises off the fire, pushed outward a little on kicks.
  inferno: { zoom: 1.002, zoomK: 0.008, dy: 0.0020, turb: 0.0018, decay: 0.93, shift: 0.05, gain: 0.8, cx: 0.5, cy: 0.85 },
  // Rising light: the curtains' brightest rays leave a slow upward wisp, like the aurora's own drift.
  aurora:  { zoom: 1.0, dy: 0.0011, turb: 0.0004, decay: 0.95, shift: 0.04, gain: 0.7, cx: 0.5, cy: 0.5 },
  // The water already remembers: only a faint, short wet sheen that drifts with the current.
  ink:     { zoom: 1.0, turb: 0.0006, decay: 0.86, shift: 0.02, gain: 0.32, cx: 0.5, cy: 0.5 },
  // Phosphor persistence: printed dots linger a beat on the glass, no drift at all.
  teletype:{ zoom: 1.0, decay: 0.80, shift: 0.02, gain: 0.35, cx: 0.5, cy: 0.5 },
  // Incense: the lit dust drifts slowly upward through the shafts.
  sanctum: { zoom: 1.0, dy: 0.0008, turb: 0.0004, decay: 0.95, shift: 0.03, gain: 0.5, cx: 0.5, cy: 0.4 },
  // Speed: the lights streak toward the camera, hardest when the cycles run.
  grid:    { zoom: 1.006, zoomK: 0.02, zoomS: 0.004, decay: 0.90, shift: 0.05, gain: 0.7, cx: 0.5, cy: 0.62 },
  // Slipstream: the lit vapour trails past and up, a little harder on kicks.
  aether:  { zoom: 1.006, zoomK: 0.014, zoomS: 0.004, dy: 0.0007, turb: 0.0009, decay: 0.92, shift: 0.05, gain: 0.7, cx: 0.5, cy: 0.5 },
  // Persistence of vision: the seams streak and turn with the mandala, hard on kicks.
  mandala: { zoom: 1.008, zoomK: 0.022, rot: 0.0022, swirl: 0.015, swirlK: 0.035, decay: 0.92, shift: 0.07, gain: 0.9, cx: 0.5, cy: 0.5 }
}

function of(name) {
  var s = styles[name] || {}, o = {}
  for (var k in base) o[k] = s[k] !== undefined ? s[k] : base[k]
  return o
}

function blend(a, b, t) {
  if (t >= 1) return b
  var o = {}
  for (var k in base) o[k] = a[k] + (b[k] - a[k]) * t
  return o
}

// The per-frame warp uniforms for this frame's music.
// m: { kick, swell, snap, flow, time, full (0|1), light (0|1), dt (60 / fps) }
function warp(p, m) {
  var dt = m.dt > 0 ? m.dt : 1
  var zoom = Math.pow(p.zoom + p.zoomK * m.kick + p.zoomS * m.swell, dt)
  // The turn eases from one way to the other over a minute, so nothing spins forever.
  var dir = Math.sin(m.time * 0.05) >= 0 ? 1 : -1
  var rot = (p.rot * dir + p.rotK * m.kick * dir) * dt
  var swirl = (p.swirl + p.swirlK * m.kick) * dir * dt
  var ripple = p.ripple + p.rippleK * m.kick
  var decay = Math.pow(m.full ? p.decay : p.decay * p.decay, dt)
  var shift = 1 - Math.pow(1 - p.shift, dt)
  var gain = p.gain * (m.full ? 1.0 : 0.55) * (m.light ? 0.45 : 1.0)
  return { a: [zoom, rot, swirl, ripple],
           b: [p.dx * dt, p.dy * dt, decay, shift],
           c: [p.cx, p.cy, p.smear + p.smearK * m.kick, p.turb * dt],
           gain: gain }
}
