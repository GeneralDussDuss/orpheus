.pragma library

// The cassette deck's numbers (Cassette.qml), pure so they test headless.
// Units are normalized: a full pack is radius 1 (rMax), times are seconds.

var R_MIN = 0.42                          // an empty pack: the spool core
var R_HUB = 0.30                          // the drive spindle's tooth ring
// Tape speed: 0.75 rev/s on an empty reel, 0.315 on a full one.
var V = 2 * Math.PI * R_MIN * 0.75
var A = R_MIN * R_MIN, B = 1 - A

function frac(pos, len) { return len > 0 ? Math.max(0, Math.min(1, pos / len)) : 0 }

// Pack radii, area-exact: the tape that leaves one reel lands on the other.
function takeR(p)   { return Math.sqrt(A + B * p) }          // the right reel grows
function supplyR(p) { return Math.sqrt(A + B * (1 - p)) }    // the left reel shrinks

// θ(p) = ∫ V/r dt in closed form, so the angle is a function of the tape and
// never drifts. Both reels turn the same way (visual CCW), both increase with
// the position, and the emptier one turns faster. With no length (a stream)
// the reels just turn at a middling radius.
function takeAngle(pos, len) {
  if (!(len > 0)) return V / 0.7 * Math.max(0, pos)
  return 2 * V * len / B * (takeR(frac(pos, len)) - R_MIN)
}
function supplyAngle(pos, len) {
  if (!(len > 0)) return V / 0.7 * Math.max(0, pos)
  return 2 * V * len / B * (1 - supplyR(frac(pos, len)))
}
function revs(pos, len) { return takeAngle(pos, len) / (2 * Math.PI) }

// The three counter drums, as fractional digit positions [ones, tens, hundreds]:
// the ones drum rolls continuously, a higher drum rolls only during the last
// tenth of the drum below it (the carry).
function drums(r) {
  var v = Math.max(0, r) % 1000, out = []
  for (var k = 0; k < 3; k++) {
    var x = v / Math.pow(10, k), d = Math.floor(x) % 10, f = x - Math.floor(x)
    out.push(k === 0 ? d + f : d + Math.max(0, Math.min(1, f * 10 - 9)))
  }
  return out
}

// Scrub gear: a screen-angle delta (radians, atan2 in y-down space) to seconds
// of tape. One full turn is 30 s; counter-clockwise on screen (dA < 0) is forward.
var SECONDS_PER_TURN = 30
function scrubDelta(dA) {
  if (dA > Math.PI) dA -= 2 * Math.PI
  else if (dA < -Math.PI) dA += 2 * Math.PI
  return -dA / (2 * Math.PI) * SECONDS_PER_TURN
}

// VU: the mean of bands [lo, hi) mapped onto the scale, with a little floor
// taken off so room noise does not lift the needle.
function vuTarget(levels, lo, hi) {
  var s = 0, n = 0
  for (var i = lo; i < hi && i < levels.length; i++) { s += levels[i] || 0; n++ }
  if (!n) return 0
  return Math.pow(Math.max(0, Math.min(1, (s / n - 0.05) / 0.75)), 0.8)
}
// The needle: a damped spring (≈0.4 s settle, a small overshoot) on pegs at
// 0 and just past full scale. Semi-implicit Euler; returns [x, v].
var W0 = 14, ZETA = 0.66
function needleStep(x, v, target, dt) {
  v += (W0 * W0 * (target - x) - 2 * ZETA * W0 * v) * dt
  x += v * dt
  if (x < 0) { x = 0; v = Math.max(0, v) }
  else if (x > 1.06) { x = 1.06; v = Math.min(0, v) }
  return [x, v]
}

// The j-card: a "tape" is a page of 2·rows tracks of the play order, and its
// two sides split that page evenly. `index` is the playing order position.
function page(index, rows, length) {
  var per = Math.max(2, rows * 2), pg = Math.floor(Math.max(0, index) / per), first = pg * per
  var m = Math.max(0, Math.min(per, length - first)), split = Math.ceil(m / 2)
  return { page: pg, pages: Math.max(1, Math.ceil(length / per)), first: first, count: m, split: split,
           side: index - first < split ? "a" : "b" }
}

function clock(s) {
  s = Math.max(0, Math.floor(s || 0))
  var m = Math.floor(s / 60), r = s % 60
  return m + ":" + (r < 10 ? "0" : "") + r
}
function sideTime(tracks) {
  var t = 0
  for (var i = 0; i < tracks.length; i++) t += tracks[i].duration || 0
  return t
}
function lpad(n, w) { var s = String(n); while (s.length < w) s = " " + s; return s }
