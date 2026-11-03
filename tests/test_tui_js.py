"""Tui.js's text helpers, run headless in a QJSEngine (no window)."""
import unittest
from pathlib import Path

try:
    from PySide6.QtCore import QCoreApplication
    from PySide6.QtQml import QJSEngine
except ImportError:          # the daemon-only install has no Qt
    QJSEngine = None

SRC = Path(__file__).resolve().parent.parent / "Tui.js"


@unittest.skipUnless(QJSEngine is not None, "PySide6 is not installed")
class TuiJsTest(unittest.TestCase):
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

    def test_fit_ascii(self):
        self.assertEqual(self.ev('fit("abcdef", 6)'), "abcdef")
        self.assertEqual(self.ev('fit("abcdefg", 6)'), "abcde…")

    def test_fit_counts_wide_cells(self):
        out = self.ev('fit("東京 Tokyo 日本語のアルバム", 8)')
        self.assertLessEqual(self.ev(f"cells({out!r})"), 8)
        self.assertTrue(out.endswith("…"))
        self.assertEqual(self.ev('fit("日本語", 6)'), "日本語")      # exactly 6 cells: kept whole

    def test_fit_never_splits_a_surrogate_pair(self):
        out = self.ev('fit("😀😀😀😀😀", 4)')
        self.assertEqual(out, "😀…")
        for ch in out:
            self.assertFalse(0xD800 <= ord(ch) <= 0xDFFF)

    def test_px_follows_the_body_size(self):
        self.assertEqual(self.ev('px("title", 13)'), 17)
        self.assertEqual(self.ev('px("hero", 26)'), 52)
        self.assertGreater(self.ev('px("lead", 15)'), 15)            # still above body text at 15 px


if __name__ == "__main__":
    unittest.main()
