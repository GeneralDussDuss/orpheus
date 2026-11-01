"""No QML file gives an object an id that is also a property name in that file.

QML resolves an unqualified name to a component id before the scope object's
own property, so `opacity: shown * rest` on an item with `property real rest`
read the Column whose id was `rest`: NaN, and the fullscreen show drew no
visualizer at all. Plain text, no Qt needed."""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FILES = sorted(ROOT.glob("*.qml")) + sorted((ROOT / "orpheusd" / "desktop" / "qml").glob("*.qml"))

# An object id: `id: name` alone on its line, or inside `{ ...; id: name; ... }`.
ID = re.compile(r"(?:^|[{;])[ \t]*id:[ \t]*([A-Za-z_]\w*)[ \t]*(?=$|[;}])", re.M)
PROP = re.compile(r"\bproperty\s+(?:alias|[\w.<>]+)\s+([A-Za-z_]\w*)")


def strip_comments(s: str) -> str:
    s = re.sub(r"/\*.*?\*/", "", s, flags=re.S)
    return re.sub(r"(?m)//.*$", "", s)


class QmlIdsTest(unittest.TestCase):
    def test_found_the_qml(self):
        self.assertIn("StageView.qml", [f.name for f in FILES])

    def test_no_id_shadows_a_property(self):
        clashes = {}
        for f in FILES:
            s = strip_comments(f.read_text(encoding="utf-8"))
            both = set(ID.findall(s)) & set(PROP.findall(s))
            if both:
                clashes[f.name] = sorted(both)
        self.assertEqual(clashes, {}, "rename the id (or qualify every use of the property)")

    def test_the_pattern_catches_the_original_bug(self):
        bug = "Loader { property real rest: 1; opacity: shown * rest }\nColumn {\n  id: rest\n}\n"
        self.assertEqual(set(ID.findall(bug)) & set(PROP.findall(bug)), {"rest"})


if __name__ == "__main__":
    unittest.main()
