"""Pilgrim.js's pure route logic, run headless in a QJSEngine (no window)."""
import json
import unittest
from pathlib import Path

try:
    from PySide6.QtCore import QCoreApplication
    from PySide6.QtQml import QJSEngine
except ImportError:          # the daemon-only install has no Qt
    QJSEngine = None

SRC = Path(__file__).resolve().parent.parent / "Pilgrim.js"


@unittest.skipUnless(QJSEngine is not None, "PySide6 is not installed")
class PilgrimJsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = QCoreApplication.instance() or QCoreApplication([])
        cls.js = QJSEngine()
        r = cls.js.evaluate(SRC.read_text(encoding="utf-8").replace(".pragma library", "", 1))
        assert not r.isError(), r.toString()

    def ev(self, expr):
        r = self.js.evaluate(expr)
        self.assertFalse(r.isError(), r.toString())
        return r.toVariant()

    def test_resolve_filters_and_falls_back(self):
        r = json.loads(self.ev('JSON.stringify(resolve(null, ["abyss","@organ","aurora","tunnel","horizon"]))'))
        self.assertEqual(r["drop"], ["abyss"])          # @descent/@mandelbox missing -> filtered
        self.assertEqual(r["build"], ["@organ"])
        self.assertEqual(r["breakdown"], ["aurora"])    # list emptied -> fallback
        self.assertEqual(r["intro"], ["aurora"])

    def test_resolve_overlays_the_config_route(self):
        r = json.loads(self.ev(
            'JSON.stringify(resolve({drop: ["tunnel", "abyss"]}, ["abyss","aurora","tunnel","horizon"]))'))
        self.assertEqual(r["drop"], ["tunnel", "abyss"])
        self.assertEqual(r["steady"], ["horizon"])      # untouched keys keep the defaults (then fallback)

    def test_resolve_ignores_malformed_route(self):
        base = 'resolve(%s, ["abyss","aurora","tunnel","horizon"])'
        for bad in ('"x"', '42', '({drop: "abyss"})', '({drop: [1, {}]})'):
            r = json.loads(self.ev('JSON.stringify(' + base % bad + ')'))
            self.assertEqual(r["drop"], ["abyss"], bad)  # defaults, not a throw

    def test_ordinals(self):
        secs = '[{code:4},{code:1},{code:2},{code:4},{code:2}]'
        self.assertEqual(self.ev('JSON.stringify(ordinals(%s))' % secs), '[0,0,0,1,1]')
        self.assertEqual(self.ev('JSON.stringify(ordinals(null))'), '[]')

    def test_leg_rotates_and_never_repeats_current(self):
        res = '({drop:["a","b","c"]})'
        self.assertEqual(self.ev('leg(%s, 2, 0, "", [], 0)' % res), "a")
        self.assertEqual(self.ev('leg(%s, 2, 1, "", [], 0)' % res), "b")
        self.assertEqual(self.ev('leg(%s, 2, 0, "a", [], 0)' % res), "b")       # skips current
        self.assertEqual(self.ev('leg(%s, 2, 0, "a", ["b"], 0)' % res), "c")    # and banned
        self.assertEqual(self.ev('leg(({drop:["a"]}), 2, 3, "a", [], 0)'), "a")  # single entry stays
        self.assertEqual(self.ev('leg(%s, 2, 0, "", ["a","b","c"], 0)' % res), "a")  # all banned: list kept

    def test_leg_seed_shifts_rotation(self):
        res = '({drop:["a","b","c"]})'
        self.assertEqual(self.ev('leg(%s, 2, 0, "", [], 1)' % res), "b")
        self.assertNotEqual(self.ev('seedOf("12345")'), self.ev('seedOf("12346")'))
        self.assertEqual(self.ev('seedOf("")'), 0)
        self.assertEqual(self.ev('seedOf("42")'), self.ev('seedOf("42")'))

    def test_timing_clamps(self):
        for bpm, drop_ms, build_ms in ((70, 2500, 4000), (128, 1875, 3750), (174, 1379, 2759)):
            t = json.loads(self.ev('JSON.stringify(timing(2, %s, true))' % (60.0 / bpm)))
            self.assertAlmostEqual(t["ms"], drop_ms, delta=1)
            self.assertEqual(t["kind"], 1)
            t = json.loads(self.ev('JSON.stringify(timing(1, %s, true))' % (60.0 / bpm)))
            self.assertAlmostEqual(t["ms"], build_ms, delta=1)
            self.assertEqual(t["kind"], 5)
        t = json.loads(self.ev('JSON.stringify(timing(3, 0, false))'))
        self.assertEqual(t, {"ms": 2000, "kind": 4})     # no grid: finite, melt for breakdowns
        t = json.loads(self.ev('JSON.stringify(timing(4, 60/128, false))'))
        self.assertAlmostEqual(t["ms"], 1875, delta=1)   # unmapped: one bar
        self.assertEqual(t["kind"], 5)


if __name__ == "__main__":
    unittest.main()
