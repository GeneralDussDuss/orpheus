.pragma library

// Small colour helpers for the TUI look: mixing and a WCAG contrast guard
// that nudges lightness (never hue) until text stays readable.

function lum(c) {
  function ch(v) { return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4) }
  return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b)
}

function contrast(a, b) {
  var x = lum(a), y = lum(b)
  return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05)
}

function mix(a, b, t) {
  return Qt.rgba(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, 1)
}

function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

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

var SCRAMBLE = "▖▗▘▙▚▛▜▝▞▟░▒▓<>/\\|=+*#%@01"

// Text mid-decode: settled characters from the left, noise for the rest.
function decode(text, progress, seed) {
  text = String(text || "")
  if (progress >= 1) return text
  var settled = Math.floor(text.length * Math.max(0, progress))
  var out = text.slice(0, settled)
  for (var i = settled; i < text.length; i++) {
    var c = text.charAt(i)
    out += c === " " ? " " : SCRAMBLE.charAt(Math.floor(Math.abs(Math.sin((i + 1) * 12.9898 + seed) * 43758.5453)) % SCRAMBLE.length)
  }
  return out
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
