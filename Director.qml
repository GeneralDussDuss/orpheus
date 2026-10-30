import QtQml

// The director: a beat grid that predicts where the beats fall, and a reading
// of the song's structure (intro, build, drop, breakdown, steady), from the
// per-frame onsets Service.qml already computes. Service feeds it one call per
// audio frame (frame) and one per clock tick (tick); everything here runs on
// the clock it is handed, so a test can drive it with a fake one.
//
// Beat grid. The pace estimate (Service's autocorrelation tempo) picks the
// octave; the grid then measures phase as the circular mean of the recent
// onsets (each onset is a unit phasor at its position in the beat, weighted by
// strength and recency). The phasor's angle is the grid's phase error, and its
// length -- corrected for how many onsets there were, so three random hits do
// not look like a groove -- is how coherent the beat is. Each update also tries
// periods within +-2.4 % and keeps the most coherent: a phase-locked loop whose
// phase detector is the phasor and whose loop filter is the two easings below.
// Between updates the grid free-runs, so it predicts: beatPhase is evaluated
// `lookahead` seconds ahead of the audio clock, cancelling the time the sound
// took to get through capture, cava's FFT window and smoothing, and onset
// detection, plus a frame or so of presentation.
//
// Downbeats: beat 1 is the slot (of four) where the spectrum changes most --
// chord and bass-note changes, crashes, sections -- scored per beat and
// decayed per bar. A drop re-anchors the bar on the beat it lands on.
//
// Structure. Followers over energy, sub-bass, high band and hat density:
//   build      sub-bass gone (its floor between kicks, so kicks alone do not
//              count as bass) while the energy, the highs or the hat density
//              climb; integrated into a 0..1 tension that holds while it lasts.
//   drop       a kick that brings the sub back at full energy after a build
//              (or a breakdown): fires `drop`, re-anchors the bar.
//   breakdown  sub and kicks gone, after the track has had a groove.
//   intro      from the start until something else happens (32 bars at most).
//   steady     everything else.
// A section must be wanted for a bar or two before it is entered and lasts at
// least two bars (a drop eight), so it does not flicker.
QtObject {
  id: d

  // ---- inputs (Service sets these) ----
  property bool enabled: true
  property bool beatLock: true
  property real lookahead: 0.085         // s, see Service.lookahead

  // ---- outputs ----
  property real beatPhase: 0
  property real barPhase: 0
  property real downbeat: 0
  property real beatConfidence: 0
  property real build: 0
  property real drop: 0
  property int sectionCode: 0            // 0 intro, 1 build, 2 drop, 3 breakdown, 4 steady
  readonly property var sectionNames: ["intro", "build", "drop", "breakdown", "steady"]
  readonly property string section: sectionNames[sectionCode]
  property int drops: 0                  // counts drops; watch it for "a drop just happened"
  property real phasePulse: 0            // exp decay from the predicted beat (what `beat` becomes when locked)
  property real lockWeight: 0            // 0..1 how much `beat` follows the grid right now

  // ---- grid state (analysis clock, seconds) ----
  property real gridA: 0                 // the time of beat number gridN
  property real gridP: 0                 // beat period; 0 = no grid yet
  property real gridN: 0
  property int downSlot: 0               // beats n with (n - downSlot) % 4 == 0 are downbeats
  property var slotScore: [0, 0, 0, 0]
  property real downHoldUntil: 0         // beat number until which a drop's bar alignment is kept
  property real coherence: 0             // last raw (bias-corrected) phasor length, for inspection
  property real lastGridAt: -1
  property real octaveMismatch: 0
  readonly property int ringCap: 480     // 8 s of frames at 60 Hz
  property var odfT: new Array(480).fill(-1e9)
  property var odfV: new Array(480).fill(0)
  property var odfL: new Array(480).fill(0)    // the low (kick) part alone: phase comes from this
  property var odfH: new Array(480).fill(0)    // the high (snare, hat) part alone
  property real pulseGain: 0                   // how hard the recent beats actually hit (0..1)
  property int odfHead: 0
  property var segSum: new Array(32).fill(0)
  property int segN: 0
  property var prevSeg: null

  // ---- structure state ----
  property real lastTs: -1
  property real eS: 0; property real eL: 0; property real eRef: 0
  property real subFast: 0; property real subRef: 0
  property real subS: 0
  property real hiS: 0; property real hiL: 0; property real hiRef: 0; property real hiFast: 0
  property var hatT: []
  property var kickT: []
  property real lastHatTs: -1
  property real lastKickTs: -1e9
  property real hatRate: 0
  property real kickRate: 0
  property var hist: []                  // every 0.5 s: [eS, hatRate, hiS]
  property real lastHistTs: -1
  property real buildHold: 0
  property real tension: 0
  property real secT0: 0
  property int candCode: -1
  property real candT0: 0
  property real dropAt: -1e9             // analysis time of the last drop's kick
  property real grooveFor: 0             // seconds of kicks + sub so far (has the track had a groove?)
  property real silentFor: 0

  function clamp01(x) { return x < 0 ? 0 : x > 1 ? 1 : x }
  function wrap(x, p) { x = x % p; if (x > p / 2) x -= p; else if (x <= -p / 2) x += p; return x }
  function barLen() { return gridP > 0 && beatConfidence > 0.3 ? 4 * gridP : 2.0 }

  function reset() {
    gridP = 0; tempoP = 0; tempoVotes = 0; gridN = 0; gridA = 0; beatConfidence = 0; downSlot = 0; slotScore = [0, 0, 0, 0]
    odfT = new Array(ringCap).fill(-1e9); odfV = new Array(ringCap).fill(0); odfL = new Array(ringCap).fill(0); odfH = new Array(ringCap).fill(0); pulseGain = 0
    build = 0; drop = 0; sectionCode = 0; secT0 = lastTs; candCode = -1; buildHold = 0; tension = 0
    grooveFor = 0; eRef = 0; subRef = 0; hiRef = 0; hist = []; hatT = []; kickT = []
    prevSeg = null; segN = 0; segSum = new Array(32).fill(0)
  }

  // One audio frame: lv = 32 levels, ms = the frame's clock, lowOn/hiOn = the
  // low/high onset strengths Service measured (0..1).
  function frame(lv, ms, lowOn, hiOn) {
    if (!enabled) return
    var ts = ms / 1000
    var dt = lastTs < 0 ? 1 / 60 : Math.max(0.004, Math.min(0.1, ts - lastTs))
    if (lastTs < 0) secT0 = ts
    if (lastTs >= 0 && (ts - lastTs > 5 || ts < lastTs)) { lastTs = ts; reset() }
    lastTs = ts

    // Onsets as events: each strength series keeps only its local peaks (the
    // previous frame is decided now that this one is in), so one slow swell
    // spread over twenty frames counts once, not twenty times.
    odfT[odfHead] = ts
    var v = lowOn + 0.35 * hiOn
    var prev = (odfHead + ringCap - 1) % ringCap
    odfV[prev] = peakOf(rawV, v); odfL[prev] = peakOf(rawL, lowOn); odfH[prev] = peakOf(rawH, hiOn)
    odfV[odfHead] = v; odfL[odfHead] = lowOn; odfH[odfHead] = hiOn
    rawV = [rawV[1], v]; rawL = [rawL[1], lowOn]; rawH = [rawH[1], hiOn]
    odfHead = (odfHead + 1) % ringCap
    for (var k = 0; k < 32; k++) segSum[k] += lv[k] || 0
    segN++

    if (lastGridAt < 0 || ts - lastGridAt >= 0.25 || ts < lastGridAt) { lastGridAt = ts; updateGrid(ts) }
    // Advance the anchor past every beat the audio clock has passed.
    var guard = 0
    while (gridP > 0 && ts >= gridA + gridP && guard++ < 16) { gridA += gridP; gridN += 1; onBeat(ts) }

    structure(lv, ts, dt, lowOn, hiOn)
  }

  // ---- beat grid ------------------------------------------------------------

  // raw = the series' last two values [before, previous]; x = the newest.
  property var rawV: [0, 0]
  property var rawL: [0, 0]
  property var rawH: [0, 0]
  function peakOf(raw, x) { return raw[1] > raw[0] && raw[1] >= x ? raw[1] : 0 }

  // Phasor of the recent onsets for period p relative to gridA: [length, angle, weight sum, effective count].
  function phasor(ts, p, low) {
    var c = 0, s = 0, W = 0, W2 = 0, src = low ? odfL : odfV
    for (var i = 0; i < ringCap; i++) {
      var age = ts - odfT[i]
      if (age > 6 || age < 0) continue
      var v = src[i]
      if (v <= 0.02) continue
      var w = v * Math.exp(-age / 2.5)
      var a = 2 * Math.PI * (odfT[i] - gridA) / p
      c += w * Math.cos(a); s += w * Math.sin(a); W += w; W2 += w * w
    }
    if (W <= 0) return [0, 0, 0, 0]
    return [Math.sqrt(c * c + s * s) / W, Math.atan2(s, c), W, W * W / W2]
  }

  // Tempo for the grid: the Fourier tempogram of the onsets (phasor coherence
  // at each period from 80 to 165 BPM, log-spaced), times a broad prior
  // centred on 120 BPM. The range keeps the beat a beat: four-on-the-floor is
  // just as coherent at half speed and the hats at double, so neither may win.
  // A new tempo must beat the current one by 25 % three updates running (40 %
  // for six while the grid is locked).
  property real tempoP: 0               // the tempogram's choice (s)
  property real tempoCand: 0
  property int tempoVotes: 0
  property real lastTempoAt: -1
  function searchTempo(ts) {
    var bestS = 0, bestP = 0, curS = 0
    for (var i = 0; i <= 90; i++) {
      var bpm = 80 * Math.pow(165 / 80, i / 90)
      var p = 60 / bpm
      var ph = phasor(ts, p)
      var n = ph[3]
      var r2 = n > 3.5 ? (ph[0] * ph[0] * n - 3) / (n - 3) : 0
      var lg = Math.log(bpm / 120) / Math.LN2
      var sc = Math.max(0, r2) * Math.exp(-lg * lg / (2 * 0.5 * 0.5))
      if (sc > bestS) { bestS = sc; bestP = p }
      if (tempoP > 0 && Math.abs(p / tempoP - 1) < 0.012 && sc > curS) curS = sc
    }
    if (bestP <= 0 || bestS < 0.02) return
    if (tempoP <= 0) { tempoP = bestP; return }
    if (Math.abs(bestP / tempoP - 1) < 0.03) { tempoP += (bestP - tempoP) * 0.3; tempoVotes = 0; return }
    // Locked, a challenger needs to be clearly better for 6 s running.
    var locked = beatConfidence > 0.5
    if (bestS > curS * (locked ? 1.4 : 1.25)) {
      if (tempoCand > 0 && Math.abs(bestP / tempoCand - 1) < 0.03) tempoVotes++
      else { tempoCand = bestP; tempoVotes = 1 }
      if (tempoVotes >= (locked ? 6 : 3) || beatConfidence < 0.2) { tempoP = bestP; tempoVotes = 0 }
    } else tempoVotes = 0
  }

  // Where in the beat the onsets cluster: a narrow circular kernel (von Mises,
  // ~1/20 beat wide) swept over the beat, so off-beat hits (swung hats, a
  // syncopated kick, the snare's flam) barely move the answer -- the phasor's
  // mean angle would be dragged toward them. Returns [offset from gridA in s,
  // peak score].
  function kernelPhase(ts, p, low) {
    var src = low ? odfL : odfV, ang = [], wt = [], i
    for (i = 0; i < ringCap; i++) {
      var age = ts - odfT[i]
      if (age > 6 || age < 0 || src[i] <= 0.02) continue
      ang.push(2 * Math.PI * (odfT[i] - gridA) / p)
      wt.push(src[i] * Math.exp(-age / 2.5))
    }
    if (!ang.length) return [0, 0]
    var N = 48, sc = new Array(N), best = 0
    for (var k = 0; k < N; k++) {
      var phi = 2 * Math.PI * k / N, acc = 0
      for (i = 0; i < ang.length; i++) acc += wt[i] * Math.exp(10 * (Math.cos(ang[i] - phi) - 1))
      sc[k] = acc
      if (acc > sc[best]) best = k
    }
    var a = sc[(best + N - 1) % N], b = sc[best], g = sc[(best + 1) % N], den = a - 2 * b + g
    var off = best + (den < 0 ? 0.5 * (a - g) / den : 0)
    return [wrap(off / N * p, p), b]
  }

  function updateGrid(ts) {
    if (lastTempoAt < 0 || ts - lastTempoAt >= 1 || ts < lastTempoAt) { lastTempoAt = ts; searchTempo(ts) }
    if (!(tempoP > 0)) { beatConfidence *= 0.97; return }
    var reseed = false
    if (gridP <= 0) { reseed = true; gridA = ts; gridN = 0 }
    else if (Math.abs(tempoP / gridP - 1) > 0.05) gridP = tempoP   // a new tempo: keep the phase where it fits
    // Kicks steer the grid when there are enough of them; without kicks (a
    // build, a breakdown) all onsets may only nudge it, never flip it onto
    // the off-beat hats.
    // "Kicks" = strong low onsets on at least a third of the beats; a pad's
    // chord change once a bar is not a kick drum.
    var low = kickRate * (reseed ? tempoP : gridP) > 0.33
    var p0 = reseed ? tempoP : gridP
    var best = null, bestP = p0
    for (var k = -6; k <= 6; k++) {
      var p = p0 * (1 + k * 0.004)
      var ph = phasor(ts, p, low)
      if (!best || ph[0] > best[0]) { best = ph; bestP = p }
    }
    var n = best[3]
    // Bias-corrected coherence: E[R^2] for n random phases is 1/n.
    // Fewer than four onsets fit some period by accident, so they say nothing.
    var r2 = n > 4 ? (best[0] * best[0] * n - 1) / (n - 1) : 0
    var rub = Math.sqrt(Math.max(0, r2))
    coherence = rub
    var evidence = clamp01((best[2] - 0.3) / 1.0) * clamp01((n - 3) / 3)   // enough onsets to judge at all
    // Phase from every onset (the kernel ignores the off-beat ones anyway, and
    // on-beat snares and hats help); whether to trust it, from the kicks.
    var kp = kernelPhase(ts, bestP, false)
    if (reseed) {
      gridP = bestP
      gridA += kp[0]
      while (gridA > ts) { gridA -= gridP }
      gridN = 0
    } else if (evidence > 0) {
      var e = wrap(kp[0], gridP)
      var g = 0.4 * clamp01((rub - 0.2) / 0.3) * evidence
      // Locked, and the kicks have stopped: hold the phase (a flywheel). Off-beat
      // hats would otherwise walk the grid off the beat a nudge at a time.
      if (!low && (beatConfidence > 0.4 || Math.abs(e) > 0.12 * gridP)) g = 0
      gridA += e * g
      gridP += (bestP - gridP) * 0.1 * g + e * 0.03 * g
    }
    var inst = clamp01((rub - 0.2) / 0.4)
    if (evidence > 0 && (low || inst > beatConfidence))
      beatConfidence += (inst - beatConfidence) * (inst > beatConfidence ? 0.07 : 0.2) * evidence
    else
      beatConfidence *= 0.99         // no kicks: coast on the flywheel, slowly losing faith
  }

  // The audio clock just passed beat gridN (at gridA).
  function onBeat(ts) {
    // How hard did the beat that just ended (gridN - 1) hit?
    var tb = gridA - gridP, hit = 0, lowHit = 0, hiHit = 0
    for (var j = 0; j < ringCap; j++) {
      var dtb = odfT[j] - tb
      if (dtb < -0.08 * gridP || dtb > 0.2 * gridP) continue
      if (odfV[j] > hit) hit = odfV[j]
      if (odfL[j] > lowHit) lowHit = odfL[j]
      if (odfH[j] > hiHit) hiHit = odfH[j]
    }
    pulseGain += (Math.min(1, hit) - pulseGain) * 0.35
    if (segN > 0) {
      var cur = new Array(32), i
      for (i = 0; i < 32; i++) cur[i] = segSum[i] / segN
      if (prevSeg) {
        // Beat 1 is where the harmony moves (bass and chord bands change
        // between this beat and the last), where the kick is heaviest, and not
        // where the backbeat's snare is.
        var num = 0, den = 0
        for (i = 0; i < 16; i++) { num += Math.abs(cur[i] - prevSeg[i]); den += cur[i] + prevSeg[i] }
        var nov = den > 0.01 ? num / den : 0
        var accent = 2 * nov + lowHit - 0.5 * hiHit
        var slot = (((gridN - 1) % 4) + 4) % 4
        var sc = slotScore.slice()
        sc[slot] = sc[slot] * 0.9 + accent
        slotScore = sc
        if (gridN > downHoldUntil) {
          var bestS = 0
          for (i = 1; i < 4; i++) if (sc[i] > sc[bestS]) bestS = i
          if (bestS !== downSlot && sc[bestS] > sc[downSlot] + 0.15 * Math.abs(sc[downSlot]) + 0.1) downSlot = bestS
        }
      }
      prevSeg = cur
    }
    segSum = new Array(32).fill(0)
    segN = 0
  }

  // Display outputs at clock `ms` (both per frame and per clock tick).
  function tick(ms) {
    // No audio frames for a while (paused, stopped): let the grid's authority fade.
    var idle = lastTs < 0 ? 0 : ms / 1000 - lastTs
    if (idle > 1.5) beatConfidence = Math.min(beatConfidence, Math.exp(-(idle - 1.5)))
    if (!enabled || gridP <= 0) {
      beatPhase = 0; barPhase = 0; downbeat = 0; phasePulse = 0; lockWeight = 0
    } else {
      var td = ms / 1000 + lookahead
      var b = gridN + (td - gridA) / gridP
      beatPhase = b - Math.floor(b)
      var bb = b - downSlot
      barPhase = (((bb % 4) + 4) % 4) / 4
      var since = barPhase * 4 * gridP
      downbeat = barPhase < 0.25 ? beatConfidence * Math.exp(-since / 0.25) : 0
      // The grid's own beat pulse, scaled by how hard the beats are actually
      // hitting: through a kickless breakdown the grid keeps time quietly.
      phasePulse = Math.exp(-beatPhase * gridP / 0.085) * clamp01(pulseGain * 1.6)
      lockWeight = beatLock ? clamp01((beatConfidence - 0.4) / 0.3) : 0
    }
    var age = ms / 1000 + lookahead - dropAt
    drop = enabled && age >= 0 && age < 8 ? Math.exp(-age / 1.5) : 0
  }

  // ---- structure -----------------------------------------------------------

  function structure(lv, ts, dt, lowOn, hiOn) {
    function ease(tau) { return 1 - Math.exp(-dt / tau) }
    function hold(tau) { return Math.exp(-dt / tau) }
    var e = 0, sub = (lv[0] + lv[1] + lv[2]) / 3, hi = 0, i
    for (i = 0; i < 32; i++) e += lv[i]
    e /= 32
    for (i = 20; i < 32; i++) hi += lv[i]
    hi /= 12

    eS += (e - eS) * ease(1.0)
    eL += (e - eL) * ease(8.0)
    eRef = Math.max(eS, eRef * hold(45))
    hiS += (hi - hiS) * ease(0.8)
    hiL += (hi - hiL) * ease(8.0)
    hiRef = Math.max(hiS, hiRef * hold(45))
    hiFast += (hi - hiFast) * ease(0.1)
    subFast += (sub - subFast) * ease(0.08)
    // (cava's gravity holds a kick's bars up for most of a beat, so a kick
    // alone and a kick with a bassline read about the same: "sub" here means
    // the low end, kicks included.)
    subS += (sub - subS) * ease(0.4)
    subRef = Math.max(subS, subRef * hold(60))

    if (hiOn > 0.25 && ts - lastHatTs > 0.05) { hatT.push(ts); lastHatTs = ts }
    if (lowOn > 0.3) { if (!kickT.length || ts - kickT[kickT.length - 1] > 0.11) kickT.push(ts) }
    while (hatT.length && ts - hatT[0] > 2) hatT.shift()
    while (kickT.length && ts - kickT[0] > 3) kickT.shift()
    hatRate = hatT.length / 2
    kickRate = kickT.length / 3

    if (lastHistTs < 0 || ts - lastHistTs >= 0.5) {
      lastHistTs = ts
      var h = hist.slice()
      h.push([eS, hatRate, hiS])
      if (h.length > 17) h.shift()
      hist = h
    }
    var then = hist.length >= 9 ? hist[hist.length - 9] : (hist.length ? hist[0] : [eS, hatRate, hiS])

    // Tension: the low end gone while the top is busy (present against its
    // own reference, or climbing), more so as the energy and hat density rise.
    var subGone = clamp01(1 - subS / Math.max(0.05, 0.35 * subRef))
    var rise = clamp01((eS - then[0]) / Math.max(0.03, 0.2 * eRef))
    var hatsUp = clamp01((hatRate - then[1]) / 3)
    var hiUp = clamp01((hiS - then[2]) / Math.max(0.02, 0.2 * hiRef))
    var hiPresent = clamp01((hiS / Math.max(0.05, hiRef) - 0.35) / 0.4)
    var dense = clamp01((hatRate - 3) / 6)
    // Builds are thin and bright (high-passed: rolls, risers, filter sweeps);
    // breakdowns are full in the middle (pads, vocals). Top band against the whole.
    var bright = clamp01((hiS / Math.max(0.02, eS) - 1.1) / 0.8)
    // (A rise alone is not tension: cava's autosens lifts every quiet passage.)
    tension = subGone * clamp01(bright * (0.55 + 0.45 * Math.max(rise, hatsUp, hiUp)) + 0.15 * hiPresent + 0.35 * dense)
    build += (tension - build) * ease(tension > build ? 2.0 : 3.0)
    buildHold = Math.max(build, buildHold * hold(3))

    var bar = barLen()
    var groove = kickRate > 0.8 && subGone < 0.5
    if (groove) grooveFor += dt
    if (e < 0.01) silentFor += dt; else silentFor = 0

    // ---- the drop ----
    var sinceDrop = ts - dropAt
    // Armed by a build; fired by a kick that brings the low end back with
    // the top still lit (full band, not just the kick returning).
    // The kick lands a frame or two before its bars fill, so a strong low
    // onset stays eligible for 150 ms while the levels catch up.
    if (lowOn > 0.3) lastKickTs = ts
    var armed = buildHold > 0.45
    if (armed && ts - lastKickTs < 0.15 && sub > 0.4 * subRef && hiFast > 0.55 * hiRef && sinceDrop > 6 * bar
        && beatConfidence > 0.2) {
      fireDrop(lastKickTs)
      return
    }

    // ---- sections ----
    var want
    if (silentFor > 3) want = 0
    else if ((build > 0.45 && (grooveFor > 4 || tension > 0.6)) || (sectionCode === 1 && build > 0.2)) want = 1
    else if (grooveFor > 8 && subGone > 0.6 && kickRate < 0.75) want = 3
    else if (sectionCode === 2 && ts - secT0 < 16 * bar) want = 2
    else if (sectionCode === 0 && ts - secT0 < 32 * bar) want = 0
    else want = 4

    if (want === sectionCode) { candCode = -1; return }
    var minDur = sectionCode === 2 && want !== 1 ? 8 * bar : 2 * bar
    if (ts - secT0 < minDur && !(want === 0 && silentFor > 3)) { candCode = -1; return }
    if (candCode !== want) { candCode = want; candT0 = ts; return }
    var need = want === 1 ? bar : want === 0 ? 0 : 2 * bar
    if (ts - candT0 >= need) {
      sectionCode = want; secT0 = ts; candCode = -1
      if (want === 0) grooveFor = 0
    }
  }

  function fireDrop(ts) {
    var t = ts
    if (gridP > 0 && beatConfidence > 0.3) {
      // Land it on the grid: the beat this kick belongs to becomes beat 1.
      var nb = Math.round(gridN + (ts - gridA) / gridP)
      t = gridA + (nb - gridN) * gridP
      downSlot = ((nb % 4) + 4) % 4
      var sc = slotScore.slice(), m = Math.max(sc[0], sc[1], sc[2], sc[3])
      sc[downSlot] = m * 1.5 + 0.1
      slotScore = sc
      downHoldUntil = nb + 32
    }
    dropAt = t
    drops = drops + 1
    sectionCode = 2; secT0 = ts; candCode = -1
    build = 0; buildHold = 0
  }

  // For inspection: the onset events still in the ring, [t, all, low, high].
  function events() {
    var out = []
    for (var i = 0; i < ringCap; i++) if (odfV[i] > 0.02 || odfL[i] > 0.02) out.push([odfT[i], odfV[i], odfL[i], odfH[i]])
    out.sort(function(a, b) { return a[0] - b[0] })
    return out
  }

  function state() {
    return { gridP: gridP, gridA: gridA, gridN: gridN, downSlot: downSlot, coherence: coherence, conf: beatConfidence,
             build: build, tension: tension, section: section, drops: drops, dropAt: dropAt,
             eS: eS, eRef: eRef, subS: subS, subRef: subRef, subFast: subFast, hatRate: hatRate, kickRate: kickRate,
             hiS: hiS, pulseGain: pulseGain, grooveFor: grooveFor, slotScore: slotScore }
  }
}
