"""AutoEQ: the index, the parametric parser, the stacked filter graph, the
service and its routes, and Eq.js's parity with eq.py. Offline throughout:
the service always gets a fake fetch and a temporary cache.

Every fixture here is made up. Real AutoEq measurements are not ours to
commit (see eq.py's licence note), so not even one device's numbers are."""
import asyncio
import json
import math
import os
import re
import tempfile
import time
import unittest
from pathlib import Path

# STATE_DIR / CACHE_DIR resolve at import: point them somewhere disposable first.
_TMP = tempfile.TemporaryDirectory()
os.environ["ORPHEUS_HOME"] = _TMP.name
os.environ["LOCALAPPDATA"] = _TMP.name

import numpy as np                                         # noqa: E402
from aiohttp import web                                    # noqa: E402
from aiohttp.test_utils import TestClient, TestServer      # noqa: E402

from orpheusd import autoeq as ae                          # noqa: E402
from orpheusd import eq                                    # noqa: E402

try:
    from PySide6.QtCore import QCoreApplication
    from PySide6.QtQml import QJSEngine
except ImportError:          # the daemon-only install has no Qt
    QJSEngine = None

ROOT = Path(__file__).resolve().parent.parent

HEADER = ("# Index\n\nThis is a list of all headphones.\n\n")
LINES = [
    "- [Acme One](./oratory1990/over-ear/Acme%20One) by oratory1990",
    "- [Acme One](./crinacle/GRAS%2043AG-7%20over-ear/Acme%20One) by crinacle on GRAS 43AG-7",
    "- [Bolt X3 (passive)](./Rtings/over-ear/Bolt%20X3%20(passive)) by Rtings",
    "- [Écoute Pro](./Super%20Review/in-ear/%C3%89coute%20Pro) by Super Review",
    "- [Zed Buds](./crinacle/711%20in-ear/Zed%20Buds) by crinacle on 711",
    "- [Acme One Mk2](./Innerfidelity/over-ear/Acme%20One%20Mk2) by Innerfidelity",
    "- [Tiny 6](./Kuulokenurkka/earbud/Tiny%206) by Kuulokenurkka",
    "- [Broken](./only/two) by nobody",
    "this line is not an entry at all",
]
INDEX_FIXTURE = HEADER + "\n".join(LINES) + "\n"

PEQ_FIXTURE = """Preamp: -5.0 dB
Filter 1: ON PK Fc 3000 Hz Gain 3.2 dB Q 2.10
Filter 2: ON LSC Fc 105 Hz Gain 4.5 dB Q 0.70
Filter 3: ON PK Fc 150 Hz Gain -2.0 dB Q 0.60
Filter 4: OFF PK Fc 400 Hz Gain 1.0 dB Q 1.00
Filter 5: ON PK Fc 6000 Hz Gain -4.0 dB Q 4.00
Filter 6: ON HSC Fc 10000 Hz Gain -2.5 dB Q 0.70
Filter 7: ON PK Fc 1200 Hz Gain 1.5 dB Q 1.20
Filter 8: ON PK Fc 45 Hz Gain 1.0 dB Q 1.50
Filter 9: ON PK Fc 8000 Hz Gain 2.0 dB Q 3.00
"""


def big_index(n=1200) -> str:
    lines = [f"- [Gen {i}](./oratory1990/over-ear/Gen%20{i}) by oratory1990" for i in range(n)]
    return HEADER + "\n".join(lines) + "\n"


def fixture_state(gains=None, on=True):
    p = eq.parse_parametric(PEQ_FIXTURE)
    return eq.normalize({
        "enabled": True, "gains": gains or [0.0] * 10, "autoeqOn": on,
        "autoeq": {"path": "oratory1990/over-ear/Acme One", "name": "Acme One",
                   "source": "oratory1990", "rig": "", "form": "over-ear",
                   "preamp": p["preamp"], "filters": p["filters"]}})


class Fetch:
    """A fake network: url -> bytes|None, counting calls."""
    def __init__(self, table=None, default=None):
        self.table, self.default, self.calls = dict(table or {}), default, []

    async def __call__(self, url):
        self.calls.append(url)
        await asyncio.sleep(0)
        v = self.table.get(url, self.default)
        return v.encode("utf-8") if isinstance(v, str) else v


# ---- pure: index and URLs ----------------------------------------------------

class IndexTest(unittest.TestCase):
    def test_parse_index(self):
        rows = ae.parse_index(INDEX_FIXTURE)
        self.assertEqual(len(rows), 7)                       # the malformed two skipped
        self.assertEqual(rows[0], ["Acme One", "oratory1990", "", "over-ear", "oratory1990/over-ear/Acme One"])
        self.assertEqual(rows[1], ["Acme One", "crinacle", "GRAS 43AG-7", "over-ear",
                                   "crinacle/GRAS 43AG-7 over-ear/Acme One"])
        self.assertEqual(rows[2][4], "Rtings/over-ear/Bolt X3 (passive)")
        self.assertEqual(rows[2][0], "Bolt X3 (passive)")
        self.assertEqual(rows[3][4], "Super Review/in-ear/Écoute Pro")
        self.assertEqual(rows[3][1], "Super Review")
        self.assertEqual(rows[4][2:4], ["711", "in-ear"])
        self.assertEqual(rows[6][3], "earbud")

    def test_device_url(self):
        self.assertEqual(ae.device_url("Rtings/over-ear/Bolt X3 (passive)"),
                         ae.RAW + "Rtings/over-ear/Bolt%20X3%20(passive)/Bolt%20X3%20(passive)%20ParametricEQ.txt")
        self.assertEqual(ae.device_url("Super Review/in-ear/Écoute Pro"),
                         ae.RAW + "Super%20Review/in-ear/%C3%89coute%20Pro/%C3%89coute%20Pro%20ParametricEQ.txt")
        for bad in ("a/../b", "/a/b/c", "a\\b/c/d", "a/b", "a/b/c/d", "a/b/" + "x" * 300, "", None, 5,
                    "a//c", "http://evil/x/y"):
            with self.assertRaises(ae.AutoEqError, msg=repr(bad)) as cm:
                ae.device_url(bad)
            self.assertEqual(cm.exception.http, 400)

    def test_entry_from_path(self):
        self.assertEqual(ae.entry_from_path("crinacle/711 in-ear/Zed Buds"),
                         {"name": "Zed Buds", "source": "crinacle", "rig": "711", "form": "in-ear",
                          "path": "crinacle/711 in-ear/Zed Buds"})


# ---- pure: the parametric file -----------------------------------------------

class ParametricTest(unittest.TestCase):
    def test_parse(self):
        p = eq.parse_parametric(PEQ_FIXTURE)
        self.assertEqual(p["preamp"], -5.0)
        self.assertEqual(len(p["filters"]), 8)               # the OFF line is not one
        self.assertEqual([f["fc"] for f in p["filters"]], [3000, 105, 150, 6000, 10000, 1200, 45, 8000])
        self.assertEqual(p["filters"][1], {"type": "LSC", "fc": 105.0, "gain": 4.5, "q": 0.7})
        self.assertEqual(p["warnings"], [])

    def test_ls_hs_normalised(self):
        p = eq.parse_parametric("Preamp: -1 dB\nFilter 1: ON LS Fc 100 Hz Gain 3 dB Q 0.7\n"
                                "Filter 2: ON HS Fc 9000 Hz Gain -2 dB\n")
        self.assertEqual([f["type"] for f in p["filters"]], ["LSC", "HSC"])
        self.assertEqual(p["filters"][1]["q"], 0.7)
        self.assertTrue(any("without a Q" in w for w in p["warnings"]))

    def test_rejects(self):
        twenty_one = "".join(f"Filter {i}: ON PK Fc {100 + i} Hz Gain 1 dB Q 1\n" for i in range(1, 22))
        for text in ("", "hello", twenty_one,
                     "Filter 1: ON PK Fc 0 Hz Gain 1 dB Q 1",
                     "Filter 1: ON PK Fc 100 Hz Gain 1 dB Q 0",
                     "Filter 1: ON PK Fc 100 Hz Gain 40 dB Q 1",
                     "Filter 1: ON PK Fc nan Hz Gain 1 dB Q 1",
                     "Filter 1: ON PK Fc 1.2.3 Hz Gain 1 dB Q 1",
                     "Filter 1: ON PK Fc 100 Hz Gain 1 dB"):
            with self.assertRaises(ValueError, msg=text[:40]):
                eq.parse_parametric(text)

    def test_soft_warnings(self):
        p = eq.parse_parametric("Preamp: -2 dB\nFilter 1: ON LSC Fc 105 Hz Gain 2 dB Q 0.9\n"
                                "Filter 2: ON PK Fc 15000 Hz Gain 1 dB Q 1\n")
        self.assertEqual(len(p["filters"]), 2)
        self.assertTrue(any("shelf Q" in w and "filter 1" in w for w in p["warnings"]))
        self.assertTrue(any("10 kHz" in w for w in p["warnings"]))
        p = eq.parse_parametric("Filter 1: ON PK Fc 100 Hz Gain 1 dB Q 1\n")
        self.assertEqual(p["preamp"], 0.0)
        self.assertTrue(any("Preamp" in w for w in p["warnings"]))

    def test_fixed_band_hint(self):
        with self.assertRaisesRegex(ValueError, "AutoEQ picker"):
            eq.parse_fixed_band(PEQ_FIXTURE)


# ---- pure: the state ---------------------------------------------------------

class NormalizeTest(unittest.TestCase):
    def test_old_state(self):
        s = eq.normalize({"enabled": True, "gains": [1] * 10, "preamp": None, "preset": None})
        self.assertIsNone(s["autoeq"])
        self.assertFalse(s["autoeqOn"])

    def test_malformed(self):
        good = fixture_state()["autoeq"]
        bad = [5, "x", [], {"path": "a"}, {**good, "filters": []},
               {**good, "filters": [{"type": "XX", "fc": 1, "gain": 1, "q": 1}]},
               {**good, "filters": [{"type": "PK", "fc": float("nan"), "gain": 1, "q": 1}]},
               {**good, "filters": [{"type": "PK"}]}, {**good, "filters": [good["filters"][0]] * 21},
               {**good, "name": "n" * 301}, {**good, "preamp": "loud"}]
        for v in bad:
            s = eq.normalize({"autoeq": v, "autoeqOn": True})
            self.assertIsNone(s["autoeq"], repr(v)[:60])
            self.assertFalse(s["autoeqOn"])

    def test_extra_keys_dropped_and_round_trip(self):
        s = fixture_state()
        s2 = eq.normalize({**s, "autoeq": {**s["autoeq"], "evil": 1}})
        self.assertNotIn("evil", s2["autoeq"])
        rt = eq.normalize(json.loads(json.dumps(s2)))
        self.assertEqual(rt, s2)
        self.assertEqual(eq.normalize(rt), rt)

    def test_on_needs_selection(self):
        self.assertFalse(eq.normalize({"autoeqOn": True})["autoeqOn"])


# ---- pure: the filter graph --------------------------------------------------

STAGE_RE = re.compile(r"^(volume|equalizer|lowshelf|highshelf)@\w+=[\w=.:-]+$")


def stages_of(chain):
    assert chain.startswith("@eq:lavfi=[") and chain.endswith("]"), chain
    return chain[len("@eq:lavfi=["):-1].split(",")


class ChainTest(unittest.TestCase):
    def test_disabled(self):
        s = fixture_state()
        s["enabled"] = False
        self.assertEqual(eq.build_chain(s), "")

    def test_flat_plus_live(self):
        st = stages_of(eq.build_chain(fixture_state()))
        self.assertTrue(st[0].startswith("volume@pre="))
        self.assertEqual(len([x for x in st if "@a" in x]), 8)
        self.assertFalse(any("@b" in x for x in st))

    def test_off_is_todays_chain(self):
        self.assertEqual(eq.build_chain(fixture_state(on=False)), "")
        g = [4, 3.5, 1.5, 2, 0, -1, 0, 1.5, 2.5, 4]
        today = eq.build_chain({"enabled": True, "gains": g})
        self.assertEqual(eq.build_chain(fixture_state(g, on=False)), today)
        self.assertIn("volume@pre=-4dB", today)

    def test_stacked_exact(self):
        g = [2, 0, 0, 0, 0, -1, 0, 0, 0, 0]
        s = fixture_state(g)
        pre = eq.effective_preamp(s)
        expect = ("@eq:lavfi=[volume@pre=%gdB:precision=float," % pre
                  + "equalizer@a0=f=3000:t=q:w=2.1:g=3.2,lowshelf@a1=f=105:t=q:w=0.7:g=4.5,"
                  "equalizer@a2=f=150:t=q:w=0.6:g=-2,equalizer@a3=f=6000:t=q:w=4:g=-4,"
                  "highshelf@a4=f=10000:t=q:w=0.7:g=-2.5,equalizer@a5=f=1200:t=q:w=1.2:g=1.5,"
                  "equalizer@a6=f=45:t=q:w=1.5:g=1,equalizer@a7=f=8000:t=q:w=3:g=2,"
                  "lowshelf@b0=f=31:t=q:w=0.7:g=2,equalizer@b5=f=1000:t=q:w=1.4:g=-1]")
        chain = eq.build_chain(s)
        self.assertEqual(chain, expect)
        st = stages_of(chain)
        labels = [x.split("=")[0].split("@")[1] for x in st]
        self.assertEqual(len(labels), len(set(labels)))
        self.assertNotIn("bass", chain)
        self.assertNotIn("treble", chain)
        self.assertNotIn("t=s", chain)
        for x in st:
            self.assertRegex(x, STAGE_RE)


# ---- pure: the response and the headroom ---------------------------------------

def np_db(stages, freqs, fs=48000.0):
    """An independent implementation: RBJ by hand, H by np.polyval on z^-1."""
    w = 2 * np.pi * np.asarray(freqs, dtype=float) / fs
    zi = np.exp(-1j * w)
    total = np.zeros_like(w)
    for st in stages:
        A = 10 ** (st["gain"] / 40)
        w0 = 2 * np.pi * st["fc"] / fs
        al = np.sin(w0) / (2 * st["q"])
        c = np.cos(w0)
        r = 2 * np.sqrt(A) * al
        if st["type"] == "PK":
            b, a = [1 + al * A, -2 * c, 1 - al * A], [1 + al / A, -2 * c, 1 - al / A]
        elif st["type"] == "LSC":
            b = [A * ((A + 1) - (A - 1) * c + r), 2 * A * ((A - 1) - (A + 1) * c), A * ((A + 1) - (A - 1) * c - r)]
            a = [(A + 1) + (A - 1) * c + r, -2 * ((A - 1) + (A + 1) * c), (A + 1) + (A - 1) * c - r]
        else:
            b = [A * ((A + 1) + (A - 1) * c + r), -2 * A * ((A - 1) + (A + 1) * c), A * ((A + 1) + (A - 1) * c - r)]
            a = [(A + 1) - (A - 1) * c + r, 2 * ((A - 1) - (A + 1) * c), (A + 1) - (A - 1) * c - r]
        # polyval wants highest power first; in z^-1 that is b2
        h = np.polyval(b[::-1], zi) / np.polyval(a[::-1], zi)
        total += 20 * np.log10(np.abs(h))
    return total


class ResponseTest(unittest.TestCase):
    def test_against_numpy(self):
        s = fixture_state([3, 1, 0, -2, 0, 1.5, 0, 0, 2, -3])
        grid = list(np.geomspace(10, 22000, 500))
        mine = eq.response_db(s["gains"], s["autoeq"]["filters"], grid)
        ref = np_db(eq.band_stages(s["gains"]) + s["autoeq"]["filters"], grid)
        self.assertLess(float(np.max(np.abs(np.asarray(mine) - ref))), 1e-9)

    def test_spot(self):
        pk = {"type": "PK", "fc": 1000.0, "gain": 5.0, "q": 2.0}
        self.assertAlmostEqual(eq.stages_db([pk], [1000.0])[0], 5.0, delta=1e-6)
        ls = {"type": "LSC", "fc": 105.0, "gain": 6.0, "q": 0.7}
        self.assertAlmostEqual(eq.stages_db([ls], [20.0])[0], 6.0, delta=0.1)


class PreampTest(unittest.TestCase):
    def test_not_live(self):
        for g in ([0] * 10, [4, 3.5, 1.5, 2, 0, -1, 0, 1.5, 2.5, 4], [-3] * 10):
            s = fixture_state(g, on=False)
            self.assertEqual(eq.auto_preamp_live(s), eq.auto_preamp(g))

    def test_live(self):
        s = fixture_state()
        p = eq.auto_preamp_live(s)
        self.assertLessEqual(p, 0)
        self.assertEqual(p * 2, round(p * 2))
        grid = eq.PEAK_GRID + tuple(f["fc"] for f in s["autoeq"]["filters"])
        peak = max(eq.response_db(s["gains"], s["autoeq"]["filters"], grid))
        self.assertLessEqual(peak + p, 0.001)
        self.assertGreater(peak + p, -0.5 - 1e-9)           # rounded up, not over-cut
        self.assertLessEqual(abs(p - s["autoeq"]["preamp"]), 1.0)
        self.assertEqual(eq.effective_preamp(s), p)

    def test_clamped(self):
        s = fixture_state([12] * 10)
        s["autoeq"]["filters"].append({"type": "LSC", "fc": 105.0, "gain": 20.0, "q": 0.7})
        self.assertEqual(eq.auto_preamp_live(eq.normalize(s)), -24.0)


# ---- Eq.js parity ------------------------------------------------------------

@unittest.skipUnless(QJSEngine is not None, "PySide6 is not installed")
class EqJsParityTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = QCoreApplication.instance() or QCoreApplication([])
        cls.js = QJSEngine()
        text = (ROOT / "Eq.js").read_text(encoding="utf-8").replace(".pragma library", "", 1)
        r = cls.js.evaluate(text)
        assert not r.isError(), r.toString()

    def ev(self, expr):
        r = self.js.evaluate(expr)
        self.assertFalse(r.isError(), r.toString())
        return r.toVariant()

    def test_parity(self):
        for g in ([0] * 10, [3, 1, 0, -2, 0, 1.5, 0, 0, 2, -3], [6, 6, 0, 0, 0, 0, 0, 0, 4, 6]):
            for on in (True, False):
                s = fixture_state(g, on=on)
                filt = json.dumps(s["autoeq"]["filters"])
                grid = list(eq.PEAK_GRID)
                py = eq.response_db(g, s["autoeq"]["filters"], grid)
                js = self.ev(f"responseDb(bandStages(BANDS, {json.dumps(g)}, PEAK_Q, SHELF_Q)"
                             f".concat(stagesFromAutoeq({{filters: {filt}}})), peakGrid(), 48000)")
                self.assertEqual(len(js), len(py))
                self.assertLess(max(abs(a - b) for a, b in zip(js, py)), 1e-6)
                self.assertEqual(self.ev(f"autoPreamp({json.dumps(g)}, {filt}, {json.dumps(on)})"),
                                 eq.auto_preamp_live(s))

    def test_grid(self):
        self.assertEqual(len(self.ev("peakGrid()")), len(eq.PEAK_GRID))
        for a, b in zip(self.ev("peakGrid()"), eq.PEAK_GRID):
            self.assertAlmostEqual(a, b, places=9)

    def test_x_of_freq(self):
        self.assertAlmostEqual(self.ev("xOfFreq(31, BANDS, 40)"), 20, places=9)
        self.assertAlmostEqual(self.ev("xOfFreq(1000, BANDS, 40)"), 220, places=9)
        self.assertAlmostEqual(self.ev("xOfFreq(16000, BANDS, 40)"), 380, places=9)
        for x in (5, 20, 133, 380, 395):
            self.assertAlmostEqual(self.ev(f"xOfFreq(freqOfX({x}, BANDS, 40), BANDS, 40)"), x, places=6)


# ---- the service -------------------------------------------------------------

class ServiceTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.cache = Path(self.tmp.name)

    async def asyncTearDown(self):
        self.tmp.cleanup()

    def svc(self, fetch):
        return ae.AutoEq(self.cache, fetch=fetch)

    async def test_fetching_then_ready(self):
        f = Fetch({ae.INDEX_URL: big_index()})
        s = self.svc(f)
        r = await s.search("gen 1")
        self.assertEqual(r["state"], "fetching")
        self.assertEqual(r["results"], [])
        await s._task
        r = await s.search("gen 1")
        self.assertEqual(r["state"], "ready")
        self.assertEqual(r["count"], 1200)
        self.assertEqual(r["results"][0]["name"], "Gen 1")   # the exact match first
        self.assertEqual(len(f.calls), 1)
        self.assertTrue((self.cache / "autoeq" / "index.json").exists())
        # a fresh service reads the cache and fetches nothing
        f2 = Fetch()
        r = await self.svc(f2).search("gen 7")
        self.assertEqual(r["state"], "ready")
        self.assertEqual(f2.calls, [])

    async def test_stale_refreshes_and_serves(self):
        d = self.cache / "autoeq"
        d.mkdir(parents=True)
        rows = ae.parse_index(INDEX_FIXTURE)
        (d / "index.json").write_text(json.dumps({"v": 1, "fetchedAt": time.time() - ae.INDEX_TTL - 10,
                                                  "count": len(rows), "rows": rows}))
        f = Fetch({ae.INDEX_URL: big_index()})
        s = self.svc(f)
        r = await s.search("acme")
        self.assertEqual(r["state"], "ready")
        self.assertTrue(r["results"])
        self.assertGreater(r["age"], 29)
        await s._task
        self.assertEqual(len(f.calls), 1)
        self.assertEqual((await s.search("gen"))["count"], 1200)

    async def test_offline_shows_recent(self):
        f = Fetch({ae.device_url("crinacle/711 in-ear/Zed Buds"): PEQ_FIXTURE})
        s = self.svc(f)
        await s.device("crinacle/711 in-ear/Zed Buds")
        r = await s.search("zed")
        self.assertEqual(r["state"], "fetching")
        await s._task
        r = await s.search("zed")
        self.assertEqual(r["state"], "offline")
        self.assertIn("couldn't reach github", r["error"])
        self.assertEqual([x["name"] for x in r["results"]], ["Zed Buds"])
        self.assertEqual(r["results"][0]["rig"], "711")
        # the failure is not retried on every poll
        self.assertEqual(f.calls.count(ae.INDEX_URL), 1)

    async def test_bad_index_keeps_old(self):
        f = Fetch({ae.INDEX_URL: big_index()})
        s = self.svc(f)
        await s.refresh()
        self.assertEqual(len(s.rows), 1200)
        f.table[ae.INDEX_URL] = "<html>sign in to the wifi</html>" + INDEX_FIXTURE
        await s.refresh()
        self.assertEqual(len(s.rows), 1200)
        self.assertTrue(s.error)
        self.assertEqual((await s.search("gen 5"))["state"], "ready")

    async def test_device_cached(self):
        path = "oratory1990/over-ear/Acme One"
        f = Fetch({ae.device_url(path): PEQ_FIXTURE})
        s = self.svc(f)
        a = await s.device(path)
        b = await s.device(path)
        self.assertEqual(a["text"], PEQ_FIXTURE)
        self.assertEqual(b, a)
        self.assertEqual(len(f.calls), 1)
        # offline, no index, a new process: still works
        s2 = self.svc(Fetch())
        c = await s2.device(path)
        self.assertEqual(c["text"], PEQ_FIXTURE)
        self.assertEqual(c["entry"]["source"], "oratory1990")

    async def test_device_failures(self):
        s = self.svc(Fetch())
        with self.assertRaises(ae.AutoEqError) as cm:
            await s.device("oratory1990/over-ear/Nope")
        self.assertEqual(cm.exception.http, 502)
        s = self.svc(Fetch(default=b"x" * (ae.DEVICE_MAX + 1)))
        with self.assertRaises(ae.AutoEqError):
            await s.device("oratory1990/over-ear/Huge")
        s = self.svc(Fetch(default=b"\xff\xfe\x00bad"))
        with self.assertRaises(ae.AutoEqError):
            await s.device("oratory1990/over-ear/Latin1")

    async def test_ranking(self):
        f = Fetch({ae.INDEX_URL: big_index(1000) + "\n".join(LINES)})
        s = self.svc(f)
        await s.refresh()
        r = (await s.search("acme one"))["results"]
        self.assertEqual([(x["name"], x["source"]) for x in r[:3]],
                         [("Acme One", "oratory1990"), ("Acme One", "crinacle"), ("Acme One Mk2", "Innerfidelity")])
        r = (await s.search("bolt"))["results"]
        self.assertEqual(r[0]["name"], "Bolt X3 (passive)")
        r = (await s.search("acmeone"))["results"]            # squashed matches too
        self.assertEqual(r[0]["name"], "Acme One")
        r = (await s.search("écoute"))["results"]
        self.assertEqual(r[0]["source"], "Super Review")
        r = (await s.search("one"))["results"]                 # word start beats substring
        self.assertTrue(r[0]["name"].startswith("Acme One"))
        self.assertEqual((await s.search("zzz nothing"))["results"], [])
        self.assertEqual(len((await s.search("gen", 500))["results"]), ae.MAX_RESULTS)


# ---- the routes --------------------------------------------------------------

class FakePlayer:
    def __init__(self):
        self.eq = eq.normalize({"enabled": False, "gains": [1] + [0] * 9})

    async def set_eq(self, state):
        self.eq = eq.normalize(state)
        return {**self.eq, "preampEffective": eq.effective_preamp(self.eq)}


class RoutesTest(unittest.IsolatedAsyncioTestCase):
    PATH = "oratory1990/over-ear/Acme One"

    async def asyncSetUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.fetch = Fetch({ae.device_url(self.PATH): PEQ_FIXTURE, ae.INDEX_URL: big_index()})
        self.svc = ae.AutoEq(Path(self.tmp.name), fetch=self.fetch)
        self.player = FakePlayer()
        self.saves = 0

        def save():
            self.saves += 1
        r = web.RouteTableDef()
        ae.add_routes(r, self.svc, lambda: self.player.eq, self.player.set_eq, save)
        app = web.Application()
        app.add_routes(r)
        self.client = TestClient(TestServer(app))
        await self.client.start_server()

    async def asyncTearDown(self):
        await self.client.close()
        self.tmp.cleanup()

    async def test_apply_and_clear(self):
        r = await self.client.post("/autoeq/apply", json={"path": self.PATH})
        self.assertEqual(r.status, 200, await r.text())
        d = await r.json()
        self.assertEqual(d["autoeq"]["name"], "Acme One")
        self.assertEqual(len(d["autoeq"]["filters"]), 8)
        self.assertTrue(d["autoeqOn"])
        self.assertTrue(d["enabled"])
        self.assertEqual(d["gains"][0], 1)                    # the user's bands kept
        self.assertEqual(d["warnings"], [])
        self.assertEqual(self.saves, 1)
        self.assertIn("@a0", eq.build_chain(self.player.eq))

        r = await self.client.post("/autoeq/clear", json={})
        d = await r.json()
        self.assertIsNone(d["autoeq"])
        self.assertFalse(d["autoeqOn"])
        self.assertEqual(self.saves, 2)

    async def test_apply_failures(self):
        before = dict(self.player.eq)
        r = await self.client.post("/autoeq/apply", json={"path": "../etc/passwd"})
        self.assertEqual(r.status, 400)
        r = await self.client.post("/autoeq/apply", json={})
        self.assertEqual(r.status, 400)
        r = await self.client.post("/autoeq/apply", json={"path": "oratory1990/over-ear/Missing"})
        self.assertEqual(r.status, 502)
        self.assertIn("offline", await r.text())
        self.fetch.table[ae.device_url("Rtings/over-ear/Junk")] = "<html>not a file</html>"
        r = await self.client.post("/autoeq/apply", json={"path": "Rtings/over-ear/Junk"})
        self.assertEqual(r.status, 400)
        self.assertEqual(self.player.eq, before)
        self.assertEqual(self.saves, 0)
        self.assertEqual(self.svc.recent(), [])               # the junk was not kept

    async def test_search_caps(self):
        await self.svc.refresh()
        r = await self.client.get("/autoeq/search", params={"q": "gen", "limit": "999"})
        d = await r.json()
        self.assertEqual(d["state"], "ready")
        self.assertEqual(len(d["results"]), ae.MAX_RESULTS)
        r = await self.client.get("/autoeq/search", params={"q": "gen " + "x" * 500})
        self.assertEqual((await r.json())["results"], [])
        r = await self.client.get("/autoeq/search", params={"q": "gen 3", "limit": "junk"})
        self.assertEqual(r.status, 200)
        r = await self.client.post("/autoeq/refresh", json={})
        self.assertIn((await r.json())["state"], ("ready", "fetching"))
        await self.svc._task


# ---- merge semantics ---------------------------------------------------------

class MergeTest(unittest.TestCase):
    def test_preset_keeps_autoeq(self):
        cur = fixture_state([1] * 10)
        preset = eq.preset_by_id("bass")
        s = eq.normalize(eq.state_from_preset(preset, cur, True))
        self.assertEqual(s["autoeq"], cur["autoeq"])
        self.assertTrue(s["autoeqOn"])
        self.assertEqual(s["gains"], [float(g) for g in preset["gains"]])
        self.assertEqual(s["preset"], "bass")

    def test_band_merge_keeps_autoeq(self):
        # what POST /eq's merge branch does with EqPane's {gains, enabled} push
        cur = fixture_state()
        state = dict(cur)
        state["gains"], state["preset"], state["enabled"] = [2] * 10, None, True
        s = eq.normalize(state)
        self.assertEqual(s["autoeq"], cur["autoeq"])
        self.assertTrue(s["autoeqOn"])
        state = dict(s)
        state["enabled"] = False
        self.assertEqual(eq.normalize(state)["autoeq"], cur["autoeq"])


if __name__ == "__main__":
    unittest.main()
