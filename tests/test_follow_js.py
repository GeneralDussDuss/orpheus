"""Follow.js, the react-to-music presets, run headless in a QJSEngine."""
import json
import re
import unittest
from pathlib import Path

try:
    from PySide6.QtCore import QCoreApplication
    from PySide6.QtQml import QJSEngine
except ImportError:          # the daemon-only install has no Qt
    QJSEngine = None

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "Follow.js"


@unittest.skipUnless(QJSEngine is not None, "PySide6 is not installed")
class FollowJsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = QCoreApplication.instance() or QCoreApplication([])
        cls.js = QJSEngine()
        text = SRC.read_text(encoding="utf-8").replace(".pragma library", "", 1)
        r = cls.js.evaluate(text)
        assert not r.isError(), r.toString()

    def ev(self, expr):
        r = self.js.evaluate(expr)
        self.assertFalse(r.isError(), r.toString())
        return r.toVariant()

    def defaults(self):
        """Service.qml's own defaults for the eight, read from its source."""
        src = (ROOT / "Service.qml").read_text(encoding="utf-8")
        out = {}
        for k in self.ev("KEYS"):
            m = re.search(r"\b%s: (true|false)\b" % k, src)
            self.assertIsNotNone(m, k)
            out[k] = m.group(1) == "true"
        return out

    def test_defaults_are_a_preset(self):
        d = self.defaults()
        self.assertEqual(self.ev(f"var d = {json.dumps(d)}; detect(function(k) {{ return d[k] }})"), "subtle")

    def test_all_false_is_off(self):
        self.assertEqual(self.ev("detect(function(k) { return false })"), "off")

    def test_one_flipped_is_custom(self):
        self.assertEqual(self.ev("var v = values('subtle'); v.autoStyle = true; detect(function(k) { return v[k] })"), "custom")

    def test_values_round_trip(self):
        for n in ("off", "subtle", "full"):
            self.assertEqual(self.ev(f"var v = values('{n}'); detect(function(k) {{ return v[k] }})"), n)
        self.assertIsNone(self.ev("values('custom')"))

    def test_pilgrimage_opt_in(self):
        for n in ("off", "subtle", "full"):
            self.assertFalse(self.ev(f"values('{n}').pilgrimage"))


if __name__ == "__main__":
    unittest.main()
