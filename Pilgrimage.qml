import QtQml
import "Pilgrim.js" as Pilgrim

// Pilgrimage: the stage travels through a route of styles as the song moves
// through its sections (docs/superpowers/specs/2026-11-01-pilgrimage-design.md).
// With a trusted drop map it sets the stage style a measured lead before each
// boundary and hands Viz a landing time (landMs) and a transition kind, so the
// morph completes on the boundary itself — the drop frame included. Without
// one it follows the live section detector, downbeat-gated, with a dwell.
//
// Pure QtObject on an external clock (tick(ms)), like Director.qml, so a test
// drives it headless. It changes the stage only: config.style, the widget and
// the rail never follow a leg.
QtObject {
  id: p

  // ---- inputs (Stage binds these) ----
  property bool enabled: false
  property var styles: []                // engine.styles
  property var route: null               // config.pilgrimRoute or null
  property var map: null                 // the drop map (sections) or null
  property bool mapLocked: false         // engine.mapLocked
  property int secIdx: -1                // Director's section-ahead outputs
  property real nextSecIn: -1
  property int nextSecCode: -1
  property int sectionCode: 4            // the live detector's section
  property real beatPeriod: 0            // s per beat; 0 = no usable grid
  property bool transitioning: false     // a morph is in flight (StageView.morphing)
  property bool hidden: false
  property bool director: true
  property string trackId: ""

  // ---- outputs ----
  // On every request the timing lands first and `style` last: QML bindings
  // propagate synchronously, so a consumer bound to both always sees landMs,
  // morphMs and kind before onStyleChanged fires.
  property string style: ""
  property real landMs: -1               // >0: begin at once, land in this long
  property real morphMs: -1              // duration for a downbeat-gated morph
  property int kind: -1                  // trans.frag kind, -1 = Viz's own choice

  // ---- internal ----
  property var banned: []                // session bans (gpu failures, removed styles)
  property int armedIdx: -1              // the last boundary index consumed
  property int detourIdx: -2             // -2 none; else the secIdx (or -3, live) a manual pick holds through
  property real lastLegAt: -1e9          // clock ms of the last request (dwell, walk)
  property var ordCount: ({})            // live mode: occurrences of each section code this track
  property int lastSec: -1               // last live sectionCode seen
  property int lastIdx: -1               // last mapped secIdx seen
  property real nowMs: 0

  // Resolved on use, never cached: a change handler (onStylesChanged) can run
  // before a binding on `styles` would have updated, and a stale route then
  // hands back the very style that was just removed.
  function routeNow() { return Pilgrim.resolve(route, styles) }
  function seedNow() { return Pilgrim.seedOf(trackId) }   // same reason: onTrackIdChanged runs first
  readonly property var secOrds: Pilgrim.ordinals(map && map.sections ? map.sections : null)
  readonly property bool mapDriven: mapLocked && !!map && !!map.sections && map.sections.length > 0

  onEnabledChanged: { syncMarks(); if (enabled && !hidden) requestCurrent(); if (!enabled) idle() }
  onHiddenChanged: { syncMarks(); if (!hidden && enabled) requestCurrent() }
  onTrackIdChanged: reset()
  // The style list changed under us: re-resolve (a binding), and if the leg
  // on screen is gone, leave it at once.
  onStylesChanged: if (enabled && style && styles.length && styles.indexOf(style) < 0) skip()

  function idle() { landMs = -1; morphMs = -1; kind = -1; style = "" }
  // A track change: start the journey over, and ask for the new track's leg
  // at once (live mode carries it until the new map is ready). The old leg
  // stays on screen until the new one lands — clearing `style` would flash
  // the home style through, and a stale landMs would snap-morph into it.
  function reset() {
    armedIdx = -1; detourIdx = -2; ordCount = {}; lastLegAt = -1e9
    syncMarks()
    kind = -1; morphMs = -1; landMs = -1
    if (enabled && !hidden) requestCurrent()
  }
  function syncMarks() { lastSec = sectionCode; lastIdx = secIdx }

  function currentCode() {
    return mapDriven && secIdx >= 0 && secIdx < map.sections.length ? map.sections[secIdx].code : sectionCode
  }
  function ordinalFor(code, idx) {
    if (mapDriven && idx >= 0 && idx < secOrds.length) return secOrds[idx]
    return ordCount[code] || 0
  }

  // The one writer of the outputs; timing first, style last (see above).
  function request(name, land, morph, k) {
    if (!name || name === style) return ""
    kind = k; morphMs = morph; landMs = land
    style = name
    lastLegAt = nowMs
    return name
  }

  // The current section's leg, as a plain downbeat-gated transition: used on
  // enable, on coming back from hidden, after a seek or a track change, and
  // when a detour's section ends. It re-syncs to the route, so the leg is
  // computed with no "current" to step past: when the right style is already
  // on screen, nothing moves.
  function requestCurrent() {
    var code = currentCode()
    var t = Pilgrim.timing(code, beatPeriod, false)
    request(Pilgrim.leg(routeNow(), code, ordinalFor(code, secIdx), "", banned, seedNow()), -1, t.ms, t.kind)
  }

  function tick(ms) {
    nowMs = ms
    if (!enabled || hidden) { syncMarks(); return }

    if (mapDriven) {
      if (secIdx !== lastIdx) {
        if (secIdx < lastIdx || secIdx - lastIdx > 1) {
          // A seek: the leg is recomputed from the new index and boundaries
          // ahead may arm again — the same song replays the same journey.
          // Nothing is armed retroactively (skipped sections stay skipped).
          armedIdx = secIdx
          detourIdx = -2
          if (!transitioning) requestCurrent()
        } else if (detourIdx !== -2 && secIdx !== detourIdx) {
          // A boundary passed. A detour ends here and the route resumes.
          detourIdx = -2
          if (!transitioning) requestCurrent()
        }
        lastIdx = secIdx
      }
      lastSec = sectionCode
      var bIdx = secIdx + 1
      if (detourIdx === -2 && nextSecCode >= 0 && bIdx > armedIdx && bIdx < map.sections.length) {
        var tm = Pilgrim.timing(nextSecCode, beatPeriod, true)
        if (nextSecIn >= 0 && nextSecIn <= tm.ms / 1000) {
          if (transitioning || nextSecIn < 0.3) {
            // Inside a morph, or seen too late for a clean landing: this
            // boundary is skipped, never requested late.
            armedIdx = bIdx
          } else {
            var bar = beatPeriod > 0 ? 4 * beatPeriod : 2
            var next = map.sections[bIdx]
            var len = next.end !== undefined ? next.end - next.start : 1e9
            var intoCur = secIdx >= 0 ? (next.start - nextSecIn) - map.sections[secIdx].start : 1e9
            if (nextSecCode !== 2 && len < 4 * bar) {
              armedIdx = bIdx          // a section under 4 bars keeps the style (drops excepted)
            } else if (intoCur >= bar) {
              armedIdx = bIdx
              request(Pilgrim.leg(routeNow(), nextSecCode, ordinalFor(nextSecCode, bIdx), style, banned, seedNow()),
                      Math.round(nextSecIn * 1000), -1, tm.kind)
            }                          // else: not a bar into this section yet; try next tick
          }
        }
      }
    } else {
      lastIdx = secIdx
      if (director) {
        if (sectionCode !== lastSec) {
          var code = sectionCode
          lastSec = code
          if (detourIdx !== -2) detourIdx = -2
          if (!transitioning && ms - lastLegAt >= 16000) {
            var t = Pilgrim.timing(code, beatPeriod, false)
            var o = ordCount[code] || 0
            if (request(Pilgrim.leg(routeNow(), code, o, style, banned, seedNow()), -1, t.ms, t.kind))
              ordCount[code] = o + 1
          }
        }
      } else if (ms - lastLegAt >= 40000) {
        // No director, no sections: walk the steady list.
        var o4 = ordCount[4] || 0
        if (request(Pilgrim.leg(routeNow(), 4, o4, style, banned, seedNow()), -1, 2000, 5))
          ordCount[4] = o4 + 1
      }
    }
  }

  // `n`, the palette: morph at once, over about a bar, to the next entry for
  // this section's kind. Returns the leg's name (Stage shows the label).
  function skip() {
    var code = currentCode()
    var o = ordinalFor(code, secIdx) + 1
    var bar = beatPeriod > 0 ? Math.round(4000 * beatPeriod) : 2000
    var nm = request(Pilgrim.leg(routeNow(), code, o, style, banned, seedNow()),
                     Math.max(300, Math.min(5000, bar)), -1, Pilgrim.timing(code, beatPeriod, false).kind)
    if (nm && !mapDriven) ordCount[code] = (ordCount[code] || 0) + 1
    return nm
  }

  // A manual pick while pilgrimage is on: the picked style holds until the
  // next section boundary, then the route resumes (spec decision 7).
  function detour(name) {
    if (styles.indexOf(name) < 0) return
    detourIdx = mapDriven ? secIdx : -3
    kind = -1; morphMs = -1; landMs = -1
    if (name !== style) { style = name; lastLegAt = nowMs }
  }

  // Session ban (gpu failure or removal); a banned style on screen is left at once.
  function ban(name) {
    if (banned.indexOf(name) >= 0) return
    var b = banned.slice(); b.push(name); banned = b
    if (enabled && style === name) skip()
  }
}
