"""Cassette.js, the deck's maths, run headless in a QJSEngine (no window)."""
import math
import unittest
from pathlib import Path

try:
    from PySide6.QtCore import QCoreApplication
    from PySide6.QtQml import QJSEngine
except ImportError:          # the daemon-only install has no Qt
    QJSEngine = None

SRC = Path(__file__).resolve().parent.parent / "Cassette.js"


@unittest.skipUnless(QJSEngine is not None, "PySide6 is not installed")
class CassetteJsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # a QJSEngine wants an application object (one per process, maybe a test's)
        cls.app = QCoreApplication.instance() or QCoreApplication([])
        cls.js = QJSEngine()
        text = SRC.read_text(encoding="utf-8").replace(".pragma library", "", 1)
        r = cls.js.evaluate(text)
        assert not r.isError(), r.toString()

    def ev(self, expr):
        r = self.js.evaluate(expr)
        self.assertFalse(r.isError(), r.toString())
        return r.toVariant()

    def test_pack_radii(self):
        self.assertAlmostEqual(self.ev("takeR(0)"), 0.42, places=9)
        self.assertAlmostEqual(self.ev("takeR(1)"), 1.0, places=9)
        for p in (0, 0.1, 0.37, 0.5, 0.9, 1):
            self.assertAlmostEqual(self.ev(f"supplyR({p})"), self.ev(f"takeR(1 - {p})"), places=12)
        # area-exact: the two packs' tape area is constant
        for p in (0, 0.25, 0.5, 0.75, 1):
            a = self.ev(f"supplyR({p}) * supplyR({p}) + takeR({p}) * takeR({p})")
            self.assertAlmostEqual(a, 1 + 0.42 ** 2, places=9)

    def test_angles_start_at_zero_and_rise(self):
        self.assertEqual(self.ev("takeAngle(0, 240)"), 0)
        self.assertEqual(self.ev("supplyAngle(0, 240)"), 0)
        prev = (0.0, 0.0)
        for i in range(1, 241):
            cur = (self.ev(f"takeAngle({i}, 240)"), self.ev(f"supplyAngle({i}, 240)"))
            self.assertGreater(cur[0], prev[0])
            self.assertGreater(cur[1], prev[1])
            prev = cur

    def test_angular_speed_is_v_over_r(self):
        L, h = 240.0, 1e-3
        V = self.ev("V")
        for pos in (5, 60, 120, 200, 235):
            p = pos / L
            dt = (self.ev(f"takeAngle({pos + h}, {L})") - self.ev(f"takeAngle({pos - h}, {L})")) / (2 * h)
            self.assertAlmostEqual(dt, V / self.ev(f"takeR({p})"), delta=1e-3)
            ds = (self.ev(f"supplyAngle({pos + h}, {L})") - self.ev(f"supplyAngle({pos - h}, {L})")) / (2 * h)
            self.assertAlmostEqual(ds, V / self.ev(f"supplyR({p})"), delta=1e-3)

    def test_no_length_still_turns(self):
        self.assertGreater(self.ev("takeAngle(10, 0)"), 0)
        self.assertEqual(self.ev("takeAngle(-3, 0)"), 0)

    def test_drums(self):
        d = self.ev("drums(9.95)")
        self.assertTrue(0 < d[1] < 1, d)                  # the tens drum is mid-carry
        self.assertEqual([round(x, 9) for x in self.ev("drums(123.5)")], [3.5, 2, 1])
        self.assertEqual([round(x, 9) for x in self.ev("drums(1000)")], [0, 0, 0])
        d = self.ev("drums(99.95)")
        self.assertTrue(9 < d[1] < 10 and 0 < d[2] < 1, d)
        # the hundreds drum waits for the last turn below it, not for its own last tenth
        self.assertEqual([round(x, 9) for x in self.ev("drums(95)")], [5, 9, 0])
        self.assertEqual([round(x, 9) for x in self.ev("drums(99.5)")], [9.5, 9.5, 0.5])

    def test_scrub_gear(self):
        self.assertAlmostEqual(self.ev("scrubDelta(-Math.PI / 2)"), 7.5, places=9)
        self.assertAlmostEqual(self.ev("scrubDelta(Math.PI / 2)"), -7.5, places=9)
        # a jump across the atan2 seam is the short way round
        self.assertAlmostEqual(self.ev("scrubDelta(2 * Math.PI - 0.1)"), 0.1 / (2 * math.pi) * 30, places=9)
        self.assertAlmostEqual(self.ev("scrubDelta(-2 * Math.PI + 0.1)"), -0.1 / (2 * math.pi) * 30, places=9)

    def test_needle_spring(self):
        r = self.ev("""(function() {
            var x = 0, v = 0, peak = 0, settledAt = -1, dt = 1 / 60
            for (var i = 0; i < 120; i++) {
                var s = needleStep(x, v, 0.7, dt); x = s[0]; v = s[1]
                peak = Math.max(peak, x)
                if (Math.abs(x - 0.7) > 0.01) settledAt = -1
                else if (settledAt < 0) settledAt = (i + 1) * dt
            }
            return [peak, settledAt, x]
        })()""")
        peak, settled_at, x = r
        self.assertLess(peak - 0.7, 0.08)
        self.assertGreater(settled_at, 0)
        self.assertLess(settled_at, 0.6)
        self.assertAlmostEqual(x, 0.7, delta=0.01)
        self.assertEqual(self.ev("needleStep(0, -5, 0, 0.016)"), [0, 0])     # the bottom peg

    def test_vu_target(self):
        self.assertEqual(self.ev("vuTarget([], 0, 12)"), 0)
        self.assertEqual(self.ev("vuTarget([0, 0, 0], 0, 12)"), 0)
        self.assertAlmostEqual(self.ev("vuTarget([0.8, 0.8], 0, 12)"), 1.0, places=9)

    def test_page(self):
        p = self.ev("page(7, 4, 30)")
        self.assertEqual((p["page"], p["first"], p["count"], p["split"], p["side"]), (0, 0, 8, 4, "b"))
        p = self.ev("page(8, 4, 10)")
        self.assertEqual((p["page"], p["first"], p["count"], p["split"], p["pages"]), (1, 8, 2, 1, 2))
        self.assertEqual(self.ev("page(4, 5, 10)")["side"], "a")
        self.assertEqual(self.ev("page(5, 5, 10)")["side"], "b")
        self.assertEqual(self.ev("page(0, 4, 0)")["count"], 0)

    def test_clock(self):
        self.assertEqual(self.ev("clock(61)"), "1:01")
        self.assertEqual(self.ev("clock(-4)"), "0:00")
        self.assertEqual(self.ev("sideTime([{duration: 60}, {duration: 1.5}, {}])"), 61.5)
        self.assertEqual(self.ev("lpad(3, 2)"), " 3")


if __name__ == "__main__":
    unittest.main()
