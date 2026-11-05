.pragma library

// Small colour helpers for the TUI look: mixing and a WCAG contrast guard
// that nudges lightness (never hue) until text stays readable.

// Colours arrive undefined for a beat while a window's context is built or
// torn down; answer black instead of throwing, the binding re-runs right.
function lum(c) {
  if (!c) return 0
  function ch(v) { return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4) }
  return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b)
}

function contrast(a, b) {
  var x = lum(a), y = lum(b)
  return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05)
}

function mix(a, b, t) {
  if (!a || !b) return Qt.rgba(0, 0, 0, 1)
  return Qt.rgba(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, 1)
}

function alpha(c, a) { return c ? Qt.rgba(c.r, c.g, c.b, a) : Qt.rgba(0, 0, 0, a) }

// Move `fg` away from `bg` in lightness until it reaches `ratio`.
function ensure(fg, bg, ratio) {
  if (contrast(fg, bg) >= ratio) return fg
  var toward = lum(bg) > 0.4 ? Qt.rgba(0, 0, 0, 1) : Qt.rgba(1, 1, 1, 1)
  for (var t = 0.1; t <= 1.0001; t += 0.1) {
    var c = mix(fg, toward, t)
    if (contrast(c, bg) >= ratio) return c
  }
  return toward
}

// A muted text colour: as far toward the background as contrast allows.
function muted(fg, bg, ratio) {
  if (!fg || !bg) return Qt.rgba(0, 0, 0, 1)
  for (var t = 0.6; t >= 0; t -= 0.05) {
    var c = mix(fg, bg, t)
    if (contrast(c, bg) >= ratio) return c
  }
  return fg
}

// Text meter like ━━━━●──── (n cells, value 0..1).
function meter(value, n, full, empty, knob) {
  value = Math.max(0, Math.min(1, value || 0))
  var at = Math.round(value * (n - 1))
  var s = ""
  for (var i = 0; i < n; i++) s += i < at ? full : (i === at && knob ? knob : empty)
  return s
}

// ASCII and the CP437 shades: in every monospace face, one cell each.
var SCRAMBLE = "!<>-_\\/[]{}=+*^?#%&$@01░▒▓"

// CJK, Hangul, fullwidth forms, emoji: two cells, left as they are.
function wide(code) {
  return code >= 0x1100 && (code <= 0x115f || (code >= 0x2e80 && code <= 0xa4cf) || (code >= 0xac00 && code <= 0xd7a3)
                            || (code >= 0xf900 && code <= 0xfaff) || (code >= 0xfe30 && code <= 0xfe4f)
                            || (code >= 0xff00 && code <= 0xff60) || (code >= 0xffe0 && code <= 0xffe6) || code >= 0x1f000)
}

// Text mid-decode: a short all-noise beat, then settled characters sweep in
// from the left over noise. Spaces, wide glyphs and surrogate halves stay as
// they are, so a monospace line never changes width while it resolves.
// Callers churn the noise by moving `seed` (ScrambleText: ~22 Hz).
function decode(text, progress, seed) {
  text = String(text || "")
  if (progress >= 1) return text
  var settled = Math.floor(text.length * Math.max(0, (progress - 0.18) / 0.82))
  var out = text.slice(0, settled)
  for (var i = settled; i < text.length; i++) {
    var c = text.charAt(i), code = text.charCodeAt(i)
    if (c === " " || wide(code) || (code >= 0xd800 && code <= 0xdfff)) { out += c; continue }
    out += SCRAMBLE.charAt(Math.floor(Math.abs(Math.sin((i + 1) * 12.9898 + (seed || 0) * 78.233) * 43758.5453)) % SCRAMBLE.length)
  }
  return out
}

// Terminal cells in `s`: a wide glyph (CJK, fullwidth, emoji) takes two.
function cells(s) {
  s = String(s || "")
  var c = 0
  for (var i = 0; i < s.length; i++) {
    var code = s.codePointAt(i)
    if (code > 0xffff) i++
    c += wide(code) ? 2 : 1
  }
  return c
}

// `s` cut to `n` cells with an ellipsis, so a decode never outgrows its slot.
// Walks code points: a CJK title counts two cells a glyph, and a cut never
// lands between the halves of a surrogate pair.
function fit(s, n) {
  s = String(s || "")
  n = Math.max(1, Math.floor(n))
  if (s.length <= n / 2 || cells(s) <= n) return s
  var used = 0, i = 0
  while (i < s.length) {
    var code = s.codePointAt(i), w = wide(code) ? 2 : 1, len = code > 0xffff ? 2 : 1
    if (used + w > n - 1) break
    used += w
    i += len
  }
  return s.slice(0, i) + "…"
}

// Braille spectrum: `levels` (0..1) drawn as `rows` lines of braille, each
// cell holding 2 bands x 4 dots, bars growing from the bottom line up.
var DOTS_L = [0x1, 0x2, 0x4, 0x40]
var DOTS_R = [0x8, 0x10, 0x20, 0x80]
function braille(levels, cells, rows) {
  rows = rows || 2
  var bands = cells * 2, n = levels.length || 1, total = rows * 4
  var heights = []
  for (var b = 0; b < bands; b++) {
    var v = levels[Math.floor(b * n / bands)] || 0
    heights.push(Math.max(0, Math.min(total, Math.round(v * total))))
  }
  var lines = []
  for (var r = 0; r < rows; r++) {
    var floor = (rows - 1 - r) * 4            // dots below this line
    var s = ""
    for (var c = 0; c < cells; c++) {
      var bits = 0
      var hl = Math.max(0, Math.min(4, heights[c * 2] - floor))
      var hr = Math.max(0, Math.min(4, heights[c * 2 + 1] - floor))
      for (var i = 0; i < hl; i++) bits |= DOTS_L[3 - i]
      for (var j = 0; j < hr; j++) bits |= DOTS_R[3 - j]
      s += String.fromCharCode(0x2800 + bits)
    }
    lines.push(s)
  }
  return lines.join("\n")
}

function hex(c) {
  function h(v) { var x = Math.round(Math.max(0, Math.min(1, v)) * 255).toString(16); return x.length < 2 ? "0" + x : x }
  return "#" + h(c.r) + h(c.g) + h(c.b)
}

function esc(s) { return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;") }

// Keycap hints as styled text: [["space", "play"], ["n/p", "skip"]] ->
// keys in the accent colour, labels muted.
function hints(pairs, keyColor, labelColor) {
  var out = []
  for (var i = 0; i < pairs.length; i++)
    out.push('<font color="' + hex(keyColor) + '">' + esc(pairs[i][0]) + '</font>'
             + (pairs[i][1] ? ' <font color="' + hex(labelColor) + '">' + esc(pairs[i][1]) + '</font>' : ""))
  return out.join("&nbsp;&nbsp;&nbsp;")
}

// Two-tone meter as styled text: ━━━━╸──── with the filled part in `on`.
function meterRich(value, n, on, off) {
  value = Math.max(0, Math.min(1, value || 0))
  var at = Math.round(value * (n - 1))
  var filled = "", rest = ""
  for (var i = 0; i < n; i++) {
    if (i < at) filled += "━"
    else if (i === at) filled += "╸"
    else rest += "─"
  }
  return '<font color="' + hex(on) + '">' + filled + '</font><font color="' + hex(off) + '">' + rest + '</font>'
}
// meterRich with marks: fractions drawn as ╋ on the played side and ┼ ahead, in `mark`; the playhead cell wins.
function meterMarks(value, n, on, off, marks, mark) {
  value = Math.max(0, Math.min(1, value || 0))
  var at = Math.round(value * (n - 1)), set = {}
  for (var m = 0; m < (marks ? marks.length : 0); m++) set[Math.round(Math.max(0, Math.min(1, marks[m])) * (n - 1))] = true
  var out = "", cur = null, run = ""
  function flush() { if (run) out += '<font color="' + hex(cur) + '">' + run + '</font>'; run = "" }
  for (var i = 0; i < n; i++) {
    var c = i <= at ? on : off, g = i < at ? "━" : i === at ? "╸" : "─"
    if (set[i] && i !== at) { c = mark; g = i < at ? "╋" : "┼" }
    if (c !== cur) { flush(); cur = c }
    run += g
  }
  flush(); return out
}
// "drop · 1:15 · 85 %" for the marker under cell `cell` (0..n-1), else "".
function markLabel(drops, dur, n, cell, clock) {
  for (var i = 0; i < (drops ? drops.length : 0); i++)
    if (Math.round(drops[i].t / Math.max(1, dur) * (n - 1)) === cell) return "drop · " + clock(drops[i].t) + " · " + Math.round(drops[i].strength * 100) + " %"
  return ""
}

// A tiny animated level meter for the playing row: ▁▃▅ that moves with time.
var EQ = "▁▂▃▄▅▆▇"
function eq(time, seed) {
  var s = ""
  for (var i = 0; i < 3; i++) s += EQ.charAt(Math.floor((Math.sin(time * (5 + i * 1.7) + seed + i) * 0.5 + 0.5) * 6.99))
  return s
}

// The glow budget, 0..1, from config `bloom`: "off" 0, "subtle" 0.5 (the
// default, and what anything unknown reads as), "full" 1. Light themes get
// none: a halo on a pale ground reads as a smudge, not as light.
function bloom(engine) {
  if (!engine || engine.lightTheme) return 0
  var b = engine.config ? engine.config.bloom : undefined
  return b === "off" ? 0 : b === "full" ? 1 : 0.5
}

// Whole wheel notches from a wheel event, for one-step-per-notch controls. A
// notch is 120; touchpads send it in small pieces, so the remainder is kept
// on `holder.wheelAcc` (declare `property real wheelAcc: 0` on the caller).
function notches(holder, delta) {
  holder.wheelAcc += delta
  var n = holder.wheelAcc > 0 ? Math.floor(holder.wheelAcc / 120) : Math.ceil(holder.wheelAcc / 120)
  holder.wheelAcc -= n * 120
  return n
}

// A one-cell busy spinner on the shared clock (seconds): ⠋⠙⠹… at ~12 fps.
// For "this is working" where a page would otherwise sit frozen.
var SPIN = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
function spinner(time) {
  return SPIN.charAt(Math.floor(Math.max(0, time || 0) * 12) % SPIN.length)
}

// The motion scale every surface shares (ms). Press answers in-frame (TAP);
// a release or hover takes HOVER, a selection or state change STATE, a page
// or scene PAGE. Enter eases OUT, exit IN, an in-place change EASE.
var TAP = 0, TIP = 90, HOVER = 120, STATE = 180, PAGE = 420
var GLIDE = 650          // theme glide; mirrors shims.THEME_GLIDE_MS (Windows, Python-driven)
var DECODE = 520         // ScrambleText / title decode; secondary lines DECODE * 1.35
var STAGGER = 14, STAGGER_MAX = 24   // per-row print-in
var SPINNER_DELAY = 150  // never flash a spinner for a fast fetch
var EASE = 7, OUT = 6, IN = 5        // Easing.InOutCubic / OutCubic / InCubic (numeric: pragma library)
var SPRING = { spring: 6, damping: 0.4 }   // the Heart's spring; a press release
// A toast stays long enough to read: ~40 ms a character, 1.8..6 s.
function toastMs(text) { return Math.max(1800, Math.min(6000, 1400 + String(text || "").length * 40)) }

// Type scale (px at the 13 px body). Call sites write Tui.px("title", Style.font.body)
// so the steps stay relative to the user's own font size (Quickshell's Commons
// on Linux); T is the table at 13.
var T = { caption: 11, body: 13, lead: 15, title: 17, display: 21, hero: 26 }
function px(step, body) { return Math.round(T[step] * (body > 0 ? body : 13) / 13) }
var TRACK = { label: 1, brand: 2, display: 3 }

// Alpha ladder for fills over a surface.
var A = { hover: .07, tint: .12, cursor: .16, press: .3, select: .35, scrim: .6, chip: .82, card: .97 }

// "⠹  loading albums…" as styled text, the spinner in the accent.
function busy(time, label, accentHex) {
  return '<font color="' + accentHex + '">' + spinner(time) + '</font>&nbsp;&nbsp;' + esc(label || "") + '…'
}

// One scroll physics for every Flickable, and a clamped programmatic scroll
// (pair it with a contentY Behavior gated on !moving, so wheel/drag stay direct).
var FLICK = { decel: 4500, vmax: 3200 }
function scrollTo(f, y) { f.contentY = Math.max(0, Math.min(y, f.contentHeight - f.height)) }
