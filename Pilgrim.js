.pragma library

// Pilgrimage's route logic, pure and clock-free: which style each section of a
// song travels to, and how long the morph onto each boundary takes. Driven by
// Pilgrimage.qml; tested headless in tests/test_pilgrim_js.py.

var CODES = ["intro", "build", "drop", "breakdown", "steady"]

// The default journey (spec decision 1). Pack styles that are not installed
// are filtered by resolve(); a list left empty falls to FALLBACK, so the mode
// works before any pack is.
var DEFAULT_ROUTE = {
  intro: ["@cathedral"],
  build: ["@organ"],
  drop: ["abyss", "@descent", "@mandelbox"],
  breakdown: ["@drowned", "@kleinian"],
  steady: ["@cathedral", "@rosewindow"]
}
var FALLBACK = { intro: "aurora", build: "tunnel", drop: "abyss", breakdown: "aurora", steady: "horizon" }

// A deterministic, non-negative seed from the track id: the same song always
// gives the same journey (spec decision 4).
function seedOf(trackId) {
  var s = String(trackId == null ? "" : trackId), h = 0
  for (var i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) >>> 0
  return h
}

// The configured route overlaid on the default, every list filtered to styles
// that exist; anything malformed is ignored at that key, never thrown on.
function resolve(route, styles) {
  var ok = route && typeof route === "object" && !Array.isArray(route)
  var out = {}
  for (var k = 0; k < CODES.length; k++) {
    var kind = CODES[k]
    var list = ok && Array.isArray(route[kind]) ? route[kind] : DEFAULT_ROUTE[kind]
    var kept = []
    for (var i = 0; i < list.length; i++)
      if (typeof list[i] === "string" && styles.indexOf(list[i]) >= 0) kept.push(list[i])
    out[kind] = kept.length ? kept : [FALLBACK[kind]]
  }
  return out
}

// For each section of the map, its occurrence number within its own code:
// the n-th drop takes a drop list's entry n (mod length).
function ordinals(sections) {
  var out = [], seen = {}
  if (!sections || !sections.length) return out
  for (var i = 0; i < sections.length; i++) {
    var c = sections[i].code
    out.push(seen[c] || 0)
    seen[c] = (seen[c] || 0) + 1
  }
  return out
}

// The style a section travels to. Deterministic: entry (seed + ordinal) mod
// length, skipping the style already on screen (when the list has another)
// and session-banned styles (unless every entry is banned).
function leg(resolved, code, ordinal, current, banned, seed) {
  var list = resolved[CODES[code]] || [FALLBACK[CODES[code] || "steady"]]
  var n = list.length
  if (n === 1) return list[0]
  var usable = 0
  for (var i = 0; i < n; i++) if (banned.indexOf(list[i]) < 0) usable++
  var start = ((seed + ordinal) % n + n) % n
  for (var k = 0; k < n; k++) {
    var pick = list[(start + k) % n]
    if (usable > 0 && banned.indexOf(pick) >= 0) continue
    if (pick === current && k < n - 1) continue
    return pick
  }
  return list[start]
}

// How a morph onto a boundary is timed (ms) and which trans.frag kind carries
// it: drops dive (zoom), breakdowns melt, everything else veils. Mapped
// morphs run up to two bars; live ones one bar; no grid at all means 2 s.
function timing(code, beatPeriod, mapped) {
  var bar = beatPeriod > 0 ? 4000 * beatPeriod : 0
  if (code === 2) return { ms: bar ? Math.max(1200, Math.min(2500, bar)) : 2000, kind: 1 }
  var ms = bar ? Math.max(800, Math.min(4000, mapped ? 2 * bar : bar)) : 2000
  return { ms: ms, kind: code === 3 ? 4 : 5 }
}
