"""Director.qml on the drop map, driven on a fake clock (QtQml only, no window).

Each scenario runs in JavaScript inside a small wrapper object, steps the
Director at 16 ms and hands back what it saw as JSON. The canned map is 120 BPM
with beats every 0.5 s from 0, bars every 2 s, one drop at 28.0 s after a
build from 12 s.
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

WRAPPER = r"""
import QtQml
import "%(repo)s"
QtObject {
  id: w
  property string mapJson: ""
  property string which: ""
  property string result: ""
  property Director d: Director { }
  property Director plain: Director { }
  property var clock: 1000000
  readonly property var fields: ["beatPhase", "barPhase", "downbeat", "beatConfidence", "build", "drop", "sectionCode",
                                 "drops", "phasePulse", "lockWeight"]

  function fresh(conf) {
    var m = JSON.parse(mapJson)
    if (conf !== undefined) m.confidence = conf
    d.map = m
  }
  // Song time `at` (s) is where the song is at clock `clock`.
  function anchor(at) { d.songBase = at; d.songAt = clock }
  function song() { return d.playing ? (clock - d.songAt) / 1000 + d.songBase : d.songBase }
  function step(n, each) { for (var i = 0; i < n; i++) { clock += 16; d.tick(clock); if (each) each() } }

  function basic() {
    fresh(); d.playing = true; anchor(0)
    var out = { onAt: -1, w3: 0, beatWraps: [], barWraps: 0, ant: {}, armed: [], fire: null, after: null, mapped: 0, dropsEnd: 0 }
    var pb = 0, pr = 0, pa = d.armedDrop, firedAt = -1
    step(Math.round(40 / 0.016), function() {
      var t = song(), tl = t + d.mapLead
      if (d.mapOn && out.onAt < 0) out.onAt = t
      if (Math.abs(t - 3) < 0.009) out.w3 = d.mapWeight
      if (d.mapOn && d.beatPhase < pb - 0.5) out.beatWraps.push(tl)
      if (d.mapOn && d.barPhase < pr - 0.5) out.barWraps++
      pb = d.beatPhase; pr = d.barPhase
      var beatsOut = (28 - tl) / 0.5
      if (Math.abs(beatsOut - 9) < 0.02) out.ant.at9 = d.anticipate
      if (Math.abs(beatsOut - 4) < 0.02) out.ant.at4 = d.anticipate
      if (tl < 28) out.ant.last = d.anticipate
      if (d.armedDrop !== pa) { out.armed.push([tl, d.armedDrop]); pa = d.armedDrop }
      if (d.drops > 0 && firedAt < 0) { firedAt = tl; out.fire = { tl: tl, drop: d.drop, mapped: d.dropMapped, section: d.sectionCode } }
      if (firedAt >= 0 && !out.after && tl - firedAt >= 1) out.after = { dt: tl - firedAt, drop: d.drop }
    })
    out.dropsEnd = d.drops
    return out
  }

  function seekPast() {
    fresh(); d.playing = true; anchor(20)
    step(Math.round(5 / 0.016))
    anchor(35)
    step(Math.round(3 / 0.016))
    return { drops: d.drops }
  }

  function pausedSeek() {
    fresh(); d.playing = true; anchor(20)
    step(Math.round(5 / 0.016))
    var at = song(); d.playing = false; anchor(at)
    step(1)
    var frozen = d.beatPhase, moved = 0, on = d.mapOn
    step(5, function() { if (d.beatPhase !== frozen) moved++ })
    anchor(30); step(30)
    d.playing = true; anchor(30)
    step(Math.round(2 / 0.016))
    return { drops: d.drops, moved: moved, on: on }
  }

  function disagree() {
    fresh(); d.playing = true; anchor(0)
    step(Math.round(2 / 0.016))
    var on = d.mapOn
    var base = d.songAt / 1000 - d.songBase
    d.gridP = 0.5; d.gridN = 0; d.gridConf = 0.9
    d.gridA = base + d.lookahead - d.mapLead - 0.2     // the live grid 0.4 of a beat off the map
    step(Math.round(5 / 0.016))
    return { wasOn: on, agreeOff: d.agreeOff, weight: d.mapWeight, mapOn: d.mapOn }
  }

  // Frames like Service's (32 levels, low/high onsets) at 60 Hz: a 120 BPM
  // groove with a kickless, bright build from 12 to 20 s and the kick back after.
  function drive(dirs, seconds) {
    var out = []
    for (var f = 0; f < seconds * 60; f++) {
      clock += 1000 / 60
      var t = f / 60, ph = (t % 0.5) / 0.5, build = t >= 12 && t < 20
      var kick = !build && ph < 0.034, lv = []
      for (var k = 0; k < 32; k++) {
        var v = k < 3 ? (build ? 0.05 : 0.3 + 0.6 * Math.exp(-ph * 6)) : k >= 20 ? (build ? 0.4 + 0.4 * (t - 12) / 8 : 0.25) * (0.6 + 0.4 * Math.exp(-((t * 4) % 1) * 8)) : 0.3
        lv.push(v)
      }
      var hiOn = ((t * 4) % 1) < 0.034 ? 0.6 : 0
      for (var j = 0; j < dirs.length; j++) { dirs[j].frame(lv, clock, kick ? 0.9 : 0, hiOn); dirs[j].tick(clock) }
      if (f % 2 === 0) for (j = 0; j < dirs.length; j++) dirs[j].tick(clock + 8)
      var row = []
      for (j = 0; j < dirs.length; j++) { var r = []; for (k = 0; k < fields.length; k++) r.push(dirs[j][fields[k]]); row.push(r) }
      out.push(row)
    }
    return out
  }
  function sameAs(rows) {
    var diffs = 0
    for (var i = 0; i < rows.length; i++) for (var k = 0; k < fields.length; k++)
      if (rows[i][0][k] !== rows[i][1][k]) diffs++
    return diffs
  }
  function regression() {
    // A low-confidence map must leave every output as a Director without one.
    fresh(0.3); d.playing = true; anchor(0)
    var rows = drive([d, plain], 30)
    return { diffs: sameAs(rows), drops: plain.drops, conf: plain.beatConfidence, weight: d.mapWeight }
  }
  function nullMap() {
    d.map = null; d.playing = true; anchor(0)
    var rows = drive([d, plain], 30)
    return { diffs: sameAs(rows) }
  }

  onWhichChanged: if (which) result = JSON.stringify(w[which]())
}
"""

OLD = os.environ.get("ORPHEUS_OLD_DIRECTOR", "")    # optional: a pre-map Director.qml to compare against


@unittest.skipUnless(QCoreApplication is not None, "PySide6 missing")
class DirectorMapTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = QCoreApplication.instance() or QCoreApplication(sys.argv[:1])
        cls.tmpd = tempfile.TemporaryDirectory()

    @classmethod
    def tearDownClass(cls):
        cls.tmpd.cleanup()

    def run_js(self, which, wrapper=WRAPPER, repo=REPO):
        engine = QQmlEngine()
        comp = QQmlComponent(engine)
        src = wrapper.replace("%(repo)s", QUrl.fromLocalFile(str(repo)).toString())
        comp.setData(src.encode(), QUrl.fromLocalFile(str(Path(self.tmpd.name) / "w.qml")))
        obj = comp.create()
        self.assertIsNotNone(obj, comp.errorString())
        obj.setProperty("mapJson", json.dumps(MAP))
        obj.setProperty("which", which)
        out = json.loads(obj.property("result"))
        obj.deleteLater()
        return out

    def test_follows_the_map(self):
        r = self.run_js("basic")
        self.assertGreaterEqual(r["onAt"], 0)
        self.assertLess(r["onAt"], 3)
        self.assertGreater(r["w3"], 0.99)
        # The beat wraps on each map beat (one 16 ms tick late at most).
        self.assertGreater(len(r["beatWraps"]), 60)
        for tl in r["beatWraps"]:
            off = tl - round(tl / 0.5) * 0.5
            self.assertTrue(0 <= off < 0.017, tl)
        self.assertGreaterEqual(r["barWraps"], 17)
        self.assertLessEqual(r["barWraps"], 21)
        a = r["ant"]
        self.assertEqual(a["at9"], 0)
        self.assertAlmostEqual(a["at4"], 0.5, delta=0.03)
        self.assertGreater(a["last"], 0.99)
        # Armed once, 1.5 s ahead, then disarmed after the drop.
        self.assertEqual(r["armed"][0][1], 28.0)
        self.assertAlmostEqual(r["armed"][0][0], 26.5, delta=0.02)
        self.assertEqual([x[1] for x in r["armed"]], [28.0, -1])
        f = r["fire"]
        self.assertTrue(28.0 <= f["tl"] < 28.017, f)
        self.assertGreater(f["drop"], 0.98)
        self.assertEqual(f["mapped"], 1)
        self.assertEqual(f["section"], 2)
        self.assertAlmostEqual(r["after"]["drop"], 2.718281828 ** (-r["after"]["dt"] / 1.5), delta=0.02)
        self.assertEqual(r["dropsEnd"], 1)

    def test_seek_past_a_drop_does_not_fire(self):
        self.assertEqual(self.run_js("seekPast")["drops"], 0)

    def test_paused_seek_does_not_fire_and_pause_freezes(self):
        r = self.run_js("pausedSeek")
        self.assertEqual(r["drops"], 0)
        self.assertTrue(r["on"])
        self.assertEqual(r["moved"], 0)

    def test_live_grid_disagreeing_wins(self):
        r = self.run_js("disagree")
        self.assertTrue(r["wasOn"])
        self.assertTrue(r["agreeOff"])
        self.assertEqual(r["weight"], 0)
        self.assertFalse(r["mapOn"])

    def test_untrusted_map_changes_nothing(self):
        r = self.run_js("regression")
        self.assertEqual(r["diffs"], 0)
        self.assertEqual(r["weight"], 0)
        self.assertGreater(r["conf"], 0.3)          # the live grid did lock: the comparison means something
        self.assertEqual(self.run_js("nullMap")["diffs"], 0)

    @unittest.skipUnless(OLD and Path(OLD).is_file(), "ORPHEUS_OLD_DIRECTOR not set")
    def test_matches_the_director_before_the_map(self):
        d = Path(self.tmpd.name) / "old"
        d.mkdir(exist_ok=True)
        (d / "Director.qml").write_bytes(Path(OLD).read_bytes())
        wrapper = WRAPPER.replace("property Director plain: Director { }",
                                  'property var plain: Qt.createQmlObject(\'import "%(old)s"; Director { }\', w)')
        wrapper = wrapper.replace("%(old)s", QUrl.fromLocalFile(str(d)).toString())
        self.assertEqual(self.run_js("nullMap", wrapper)["diffs"], 0)


if __name__ == "__main__":
    unittest.main()
