.pragma library

// The equalizer's maths, mirrored from orpheusd/eq.py so the pane can draw
// the curve and the headroom without waiting on the daemon. The daemon stays
// the authority; tests/test_autoeq.py evaluates this file in a bare QJSEngine
// and holds it to eq.py (1e-6 dB on the response, exact on the preamp), so
// keep it free of imports and of anything QML.

var BANDS = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
var PEAK_Q = 1.4
var SHELF_Q = 0.7
var FS = 48000

// The ten bands as stages, zero bands left out exactly as build_chain does.
function bandStages(bands, gains, peakQ, shelfQ) {
  var out = [], last = bands.length - 1
  for (var i = 0; i < bands.length; i++) {
    var g = +(gains[i] || 0)
    if (Math.abs(g) < 1e-6) continue
    var t = i === 0 ? "LSC" : i === last ? "HSC" : "PK"
    out.push({ type: t, fc: bands[i], gain: g, q: t === "PK" ? peakQ : shelfQ })
  }
  return out
}

function stagesFromAutoeq(ae) {
  if (!ae || !ae.filters) return []
  var out = []
  for (var i = 0; i < ae.filters.length; i++) {
    var f = ae.filters[i]
    out.push({ type: f.type, fc: +f.fc, gain: +f.gain, q: +f.q })
  }
  return out
}

// RBJ cookbook biquad coefficients, [b, a]
function coeffs(st, fs) {
  var A = Math.pow(10, st.gain / 40)
  var w0 = 2 * Math.PI * st.fc / fs
  var alpha = Math.sin(w0) / (2 * st.q)
  var c = Math.cos(w0)
  if (st.type === "PK")
    return [[1 + alpha * A, -2 * c, 1 - alpha * A], [1 + alpha / A, -2 * c, 1 - alpha / A]]
  var sq = 2 * Math.sqrt(A) * alpha
  if (st.type === "LSC")
    return [[A * ((A + 1) - (A - 1) * c + sq), 2 * A * ((A - 1) - (A + 1) * c), A * ((A + 1) - (A - 1) * c - sq)],
            [(A + 1) + (A - 1) * c + sq, -2 * ((A - 1) + (A + 1) * c), (A + 1) + (A - 1) * c - sq]]
  return [[A * ((A + 1) + (A - 1) * c + sq), -2 * A * ((A - 1) + (A + 1) * c), A * ((A + 1) + (A - 1) * c - sq)],
          [(A + 1) - (A - 1) * c + sq, 2 * ((A - 1) - (A + 1) * c), (A + 1) - (A - 1) * c - sq]]
}

// Summed |H| in dB of a cascade, at each frequency.
function responseDb(stages, freqs, fs) {
  fs = fs || FS
  var co = []
  for (var s = 0; s < stages.length; s++) co.push(coeffs(stages[s], fs))
  var out = []
  for (var i = 0; i < freqs.length; i++) {
    var w = 2 * Math.PI * freqs[i] / fs
    var c1 = Math.cos(w), s1 = Math.sin(w), c2 = Math.cos(2 * w), s2 = Math.sin(2 * w)
    var db = 0
    for (var k = 0; k < co.length; k++) {
      var b = co[k][0], a = co[k][1]
      var nr = b[0] + b[1] * c1 + b[2] * c2, ni = b[1] * s1 + b[2] * s2
      var dr = a[0] + a[1] * c1 + a[2] * c2, di = a[1] * s1 + a[2] * s2
      db += 10 * Math.log((nr * nr + ni * ni) / (dr * dr + di * di)) / Math.LN10
    }
    out.push(db)
  }
  return out
}

// 240 log-spaced points over 20 Hz-20 kHz plus every band centre (eq.PEAK_GRID).
function peakGrid() {
  var out = []
  for (var i = 0; i < 240; i++) out.push(20 * Math.pow(1000, i / 239))
  for (var b = 0; b < BANDS.length; b++) out.push(BANDS[b])
  return out
}

// eq.auto_preamp / eq.auto_preamp_live: the biggest boost while no correction
// is live, else the top of the combined response rounded up to half a dB.
function autoPreamp(gains, aeFilters, live) {
  var peak = 0
  if (!live || !aeFilters || !aeFilters.length) {
    for (var i = 0; i < gains.length; i++) peak = Math.max(peak, +gains[i] || 0)
    return -Math.round(peak * 2) / 2
  }
  var ae = stagesFromAutoeq({ filters: aeFilters })
  var grid = peakGrid()
  for (var k = 0; k < ae.length; k++) grid.push(ae[k].fc)
  var db = responseDb(bandStages(BANDS, gains, PEAK_Q, SHELF_Q).concat(ae), grid, FS)
  for (var j = 0; j < db.length; j++) peak = Math.max(peak, db[j])
  return Math.max(-24, -Math.ceil(peak * 2 - 1e-9) / 2)
}

// Where frequency f falls across the bars: band i's column centre is
// colW*(i+0.5), log-interpolated between centres, extrapolated past the ends
// with the end spacing. Unclamped; the caller clips to its own width.
function xOfFreq(f, bands, colW) {
  var n = bands.length, L = Math.log(f) / Math.LN2
  var i = 0
  if (f >= bands[n - 1]) i = n - 2
  else while (i < n - 2 && f >= bands[i + 1]) i++
  var l0 = Math.log(bands[i]) / Math.LN2, l1 = Math.log(bands[i + 1]) / Math.LN2
  return colW * (i + 0.5) + (L - l0) / (l1 - l0) * colW
}

// The inverse, for sampling: the frequency under canvas x.
function freqOfX(x, bands, colW) {
  var n = bands.length, u = x / colW - 0.5
  var i = Math.max(0, Math.min(n - 2, Math.floor(u)))
  var l0 = Math.log(bands[i]) / Math.LN2, l1 = Math.log(bands[i + 1]) / Math.LN2
  return Math.pow(2, l0 + (u - i) * (l1 - l0))
}
