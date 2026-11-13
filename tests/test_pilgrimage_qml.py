"""Pilgrimage.qml driven on a fake clock (QtQml only, no window).

A Director runs the canned drop map (120 BPM, steady 0-12, build 12-28,
drop 28-44, steady 44-60) and a Pilgrimage hangs off its outputs; every
style request the driver makes is recorded with the landMs/morphMs/kind
that were visible at the moment the style changed.
"""
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
try:
    from PySide6.QtCore import QCoreApplication, QUrl
    from PySide6.QtQml import QQmlComponent, QQmlEngine
except ImportError:
    QCoreApplication = None

REPO = Path(__file__).resolve().parent.parent

MAP = {"v": 1, "state": "ready", "key": "tidal_1_60", "id": "1", "provider": "tidal", "duration": 60.0, "bpm": 120.0,
       "confidence": 0.8, "beats": [round(i * 0.5, 3) for i in range(120)], "strength": [1.0] * 120,
       "bars": [round(i * 2.0, 3) for i in range(30)], "drops": [{"t": 28.0, "strength": 0.85, "kind": "return"}],
       "builds": [{"start": 12.0, "peak": 28.0}],
       "sections": [{"start": 0, "end": 12, "code": 4}, {"start": 12, "end": 28, "code": 1},
                    {"start": 28, "end": 44, "code": 2}, {"start": 44, "end": 60, "code": 4}], "energy": []}

STYLES = '["abyss","aurora","tunnel","horizon","prism","@organ","@cathedral","@descent",' \
         '"@mandelbox","@drowned","@kleinian","@rosewindow"]'

WRAPPER = r"""
import QtQml
import "%(repo)s"
QtObject {
  id: w
  property string mapJson: ""
  property string which: ""
  property string result: ""
  property var clock: 1000000
  property var requests: []
  property int empties: 0

  property Director d: Director { }
  property Pilgrimage p: Pilgrimage {
    styles: %(styles)s
    trackId: "1"
    mapLocked: w.d.mapOn
    secIdx: w.d.secIdx
    nextSecIn: w.d.nextSecIn
    nextSecCode: w.d.nextSecCode
    sectionCode: w.d.sectionCode
    beatPeriod: 0.5
    director: true
  }
  property Connections rec: Connections {
    target: w.p
    function onStyleChanged() {
      if (!w.p.style) { w.empties++; return }   // a "" leg would flash the home style
      w.requests.push({ t: w.song(), style: w.p.style, landMs: w.p.landMs, morphMs: w.p.morphMs, kind: w.p.kind })
    }
  }

  function fresh() { var m = JSON.parse(mapJson); d.map = m; p.map = m }
  function anchor(at) { d.songBase = at; d.songAt = clock }
  function song() { return d.playing ? (clock - d.songAt) / 1000 + d.songBase : d.songBase }
  function step(n, each) { for (var i = 0; i < n; i++) { clock += 16; d.tick(clock); p.tick(clock); if (each) each() } }
  function landed(r) { return r.filter(function(x) { return x.landMs > 0 }) }

  function mapped() {
    fresh(); d.playing = true; anchor(0); p.enabled = true
    step(Math.round(30 / 0.016))
    var land = landed(requests)
    var build = null, drop = null
    for (var i = 0; i < land.length; i++) {
      if (land[i].style === "@organ" && !build) build = land[i]
      if (land[i].kind === 1 && !drop) drop = land[i]
    }
    return { first: requests[0], build: build, drop: drop, n: requests.length }
  }

  function shortSection() {
    var m = JSON.parse(mapJson)
    m.sections = [{start: 0, end: 12, code: 4}, {start: 12, end: 28, code: 1},
                  {start: 28, end: 33, code: 4}, {start: 33, end: 44, code: 2}, {start: 44, end: 60, code: 4}]
    m.drops = [{t: 33.0, strength: 0.85, kind: "return"}]
    m.builds = []
    d.map = m; p.map = m; d.playing = true; anchor(0); p.enabled = true
    step(Math.round(36 / 0.016))
    var at28 = requests.filter(function(x) { return x.landMs > 0 && Math.abs(x.t + x.landMs / 1000 - 28) < 0.5 })
    var at33 = requests.filter(function(x) { return x.landMs > 0 && Math.abs(x.t + x.landMs / 1000 - 33) < 0.5 })
    return { at28: at28.length, at33: at33.length, kind33: at33.length ? at33[0].kind : -1 }
  }

  function morphBlocks() {
    fresh(); d.playing = true; anchor(0); p.enabled = true
    step(Math.round(15 / 0.016), function() {
      var t = song()
      p.transitioning = t >= 6 && t <= 12.5
    })
    return { landedN: landed(requests).length }
  }

  function live() {
    p.map = null; p.sectionCode = 4; p.beatPeriod = 0
    d.playing = true; anchor(0)
    p.enabled = true
    step(Math.round(17 / 0.016))
    p.sectionCode = 1
    step(Math.round(5 / 0.016))
    p.sectionCode = 2          // 5 s later: held by the 16 s dwell
    step(Math.round(5 / 0.016))
    return { n: requests.length, first: requests.length > 1 ? requests[1] : null }
  }

  function hiddenReturn() {
    p.map = null; p.sectionCode = 4; p.beatPeriod = 0; p.hidden = true
    p.enabled = true
    step(Math.round(17 / 0.016))
    p.sectionCode = 1
    step(Math.round(17 / 0.016))
    var whileHidden = requests.length
    p.hidden = false
    step(10)
    return { whileHidden: whileHidden, onReturn: requests.length - whileHidden }
  }

  function manual() {
    fresh(); d.playing = true; anchor(0); p.enabled = true
    var out = {}
    step(Math.round(5 / 0.016))
    out.skipTo = p.skip()
    out.skipLand = p.landMs
    step(Math.round(1 / 0.016))
    p.detour("prism")
    out.picked = p.style
    step(Math.round(4 / 0.016))          // t ~ 10: still inside steady 0-12
    out.duringDetour = p.style
    step(Math.round(20 / 0.016))         // past 12 (build) and 28 (drop)
    out.afterBoundary = p.style
    return out
  }

  function banned() {
    fresh(); d.playing = true; anchor(0); p.enabled = true
    step(Math.round(5 / 0.016))
    var name = p.style
    p.ban(name)
    var after = p.style
    step(Math.round(25 / 0.016))
    var back = requests.filter(function(x) { return x.style === name })
    return { bannedName: name, after: after, cameBack: back.length - 1 }   // -1: its original request
  }

  function noSections() {
    var m = JSON.parse(mapJson); m.sections = []
    d.map = m; p.map = m; d.playing = true; anchor(0)
    p.sectionCode = 4
    p.enabled = true
    step(Math.round(17 / 0.016))
    p.sectionCode = 1
    step(Math.round(2 / 0.016))
    return { mappedRequests: landed(requests).length, total: requests.length }
  }

  function lateArm() {
    fresh(); d.playing = true; anchor(0)
    step(Math.round(11.85 / 0.016))
    p.enabled = true
    step(Math.round(8 / 0.016))
    var under = requests.filter(function(x) { return x.landMs >= 0 && x.landMs < 300 })
    return { under300: under.length }
  }

  function walk() {
    p.map = null; p.sectionCode = 4; p.beatPeriod = 0; p.director = false
    p.enabled = true
    step(Math.round(90 / 0.016))
    return { n: requests.length, styles: requests.map(function(x) { return x.style }) }
  }

  function seekReplay() {
    fresh(); d.playing = true; anchor(0); p.enabled = true
    step(Math.round(30 / 0.016))                 // through build (12) and drop (28)
    var before = requests.length
    anchor(5); step(Math.round(9 / 0.016))       // seek back into steady 0-12, run to ~14
    var organ = requests.filter(function(x) { return x.style === "@organ" })
    return { replayed: requests.length - before, organN: organ.length }
  }

  function trackChange() {
    p.map = null; p.sectionCode = 4; p.beatPeriod = 0
    p.enabled = true
    step(Math.round(2 / 0.016))
    var before = requests.length
    p.trackId = "2"
    step(10)
    var last = requests[requests.length - 1]
    return { before: before, after: requests.length, empties: empties, land: last ? last.landMs : -99 }
  }

  function unhideStable() {
    p.map = null; p.sectionCode = 4; p.beatPeriod = 0
    p.enabled = true
    step(10)
    var leg = p.style
    p.hidden = true
    step(10)
    p.hidden = false
    step(10)
    return { n: requests.length, same: p.style === leg }
  }

  function removedOnlyEntry() {
    p.map = null; p.sectionCode = 4; p.beatPeriod = 0
    p.enabled = true
    step(Math.round(17 / 0.016))
    p.sectionCode = 1                    // build: its route list is just @organ
    step(10)
    var name = p.style
    p.styles = %(styles)s.filter(function(s) { return s !== name })
    return { removed: name, after: p.style }
  }

  function removedLeg() {
    fresh(); d.playing = true; anchor(0); p.enabled = true
    step(Math.round(5 / 0.016))
    var name = p.style
    p.styles = %(styles)s.filter(function(s) { return s !== name })
    return { removed: name, after: p.style }
  }

  onWhichChanged: if (which) result = JSON.stringify(w[which]())
}
"""


@unittest.skipUnless(QCoreApplication is not None, "PySide6 missing")
class PilgrimageTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = QCoreApplication.instance() or QCoreApplication(sys.argv[:1])
        cls.tmpd = tempfile.TemporaryDirectory()

    @classmethod
    def tearDownClass(cls):
        cls.tmpd.cleanup()

    def run_js(self, which):
        engine = QQmlEngine()
        comp = QQmlComponent(engine)
        src = WRAPPER.replace("%(repo)s", QUrl.fromLocalFile(str(REPO)).toString()).replace("%(styles)s", STYLES)
        comp.setData(src.encode(), QUrl.fromLocalFile(str(Path(self.tmpd.name) / "w.qml")))
        obj = comp.create()
        self.assertIsNotNone(obj, comp.errorString())
        obj.setProperty("mapJson", json.dumps(MAP))
        obj.setProperty("which", which)
        out = json.loads(obj.property("result"))
        obj.deleteLater()
        return out

    def test_build_leg_requested_two_bars_early(self):
        r = self.run_js("mapped")
        self.assertIsNotNone(r["build"])
        # Build boundary at 12, lead = min(2 bars, 4 s) = 4 s -> requested near t = 8.
        self.assertAlmostEqual(r["build"]["t"], 8.0, delta=0.1)
        self.assertAlmostEqual(r["build"]["landMs"], 4000, delta=120)
        self.assertEqual(r["build"]["kind"], 5)
        self.assertEqual(r["build"]["style"], "@organ")

    def test_drop_leg_lands_on_the_drop(self):
        r = self.run_js("mapped")
        self.assertIsNotNone(r["drop"])
        self.assertAlmostEqual(r["drop"]["t"] + r["drop"]["landMs"] / 1000, 28.0, delta=0.05)
        self.assertEqual(r["drop"]["kind"], 1)

    def test_timing_lands_before_style(self):
        # landMs and kind are read inside onStyleChanged: stale values here
        # would mean the style landed before its timing did.
        r = self.run_js("mapped")
        self.assertGreater(r["drop"]["landMs"], 300)
        self.assertEqual(r["drop"]["kind"], 1)
        self.assertEqual(r["first"]["landMs"], -1)    # the enable request is a plain transition

    def test_short_section_keeps_the_style(self):
        r = self.run_js("shortSection")
        self.assertEqual(r["at28"], 0)                # 5 s steady slice: no morph onto it
        self.assertEqual(r["at33"], 1)                # the drop after it still lands
        self.assertEqual(r["kind33"], 1)

    def test_boundary_inside_a_morph_is_skipped(self):
        r = self.run_js("morphBlocks")
        self.assertEqual(r["landedN"], 0)

    def test_live_mode_dwell(self):
        r = self.run_js("live")
        self.assertEqual(r["n"], 2)                   # enable + first change; the flap is held
        self.assertEqual(r["first"]["landMs"], -1)
        self.assertEqual(r["first"]["morphMs"], 2000)  # no grid: 2 s
        self.assertEqual(r["first"]["kind"], 5)

    def test_hidden_holds_and_return_requests_once(self):
        r = self.run_js("hiddenReturn")
        self.assertEqual(r["whileHidden"], 0)
        self.assertEqual(r["onReturn"], 1)

    def test_skip_and_detour(self):
        r = self.run_js("manual")
        self.assertNotEqual(r["skipTo"], "")
        self.assertGreaterEqual(r["skipLand"], 300)   # a skip morphs at once, over about a bar
        self.assertEqual(r["picked"], "prism")
        self.assertEqual(r["duringDetour"], "prism")  # holds until the next boundary
        self.assertNotEqual(r["afterBoundary"], "prism")  # then the route resumes

    def test_gpu_ban_skips_at_once(self):
        r = self.run_js("banned")
        self.assertNotEqual(r["after"], r["bannedName"])
        self.assertEqual(r["cameBack"], 0)

    def test_empty_sections_falls_back_to_live(self):
        r = self.run_js("noSections")
        self.assertEqual(r["mappedRequests"], 0)
        self.assertGreaterEqual(r["total"], 2)        # the live change still lands

    def test_sub_300ms_boundary_skipped(self):
        r = self.run_js("lateArm")
        self.assertEqual(r["under300"], 0)

    def test_director_off_walks_the_steady_list(self):
        r = self.run_js("walk")
        self.assertGreaterEqual(r["n"], 3)            # enable + a walk at ~40 s and ~80 s
        for s in r["styles"]:
            self.assertIn(s, ("@cathedral", "@rosewindow", "horizon"))

    def test_seek_back_replays_the_journey(self):
        r = self.run_js("seekReplay")
        # The seek recomputes the leg from the new index, and the build
        # boundary arms again on the way back through: deterministic replay.
        self.assertGreaterEqual(r["replayed"], 2)
        self.assertEqual(r["organN"], 2)

    def test_track_change_requests_a_fresh_leg(self):
        r = self.run_js("trackChange")
        self.assertEqual(r["after"] - r["before"], 1)
        self.assertEqual(r["empties"], 0)         # never flashes the home style through ""
        self.assertEqual(r["land"], -1)           # and carries no stale landing time

    def test_unhide_keeps_the_current_leg(self):
        r = self.run_js("unhideStable")
        self.assertEqual(r["n"], 1)               # re-syncing to the same leg is not a morph
        self.assertTrue(r["same"])

    def test_removed_only_entry_falls_back(self):
        r = self.run_js("removedOnlyEntry")
        self.assertEqual(r["removed"], "@organ")
        self.assertEqual(r["after"], "tunnel")    # the build list empties -> its fallback

    def test_removed_style_on_screen_skips(self):
        r = self.run_js("removedLeg")
        self.assertNotEqual(r["after"], r["removed"])


if __name__ == "__main__":
    unittest.main()
