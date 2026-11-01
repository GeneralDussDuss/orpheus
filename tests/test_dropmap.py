"""The drop map's analysis on synthetic tracks (orpheusd/dropmap.py).

Each case is a few tens of seconds of 22050 Hz mono built here: a kick, a sub
bass, hats and a white-noise riser placed on exact beat times, so where the
beats, bars and drops are is known to the sample. Run at idle with one BLAS
thread (tests/_idle.py); nothing touches the network or ffmpeg.
"""
import contextlib
import io
import json
import os
import sys
import tempfile
import unittest
import unittest.mock
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _idle  # noqa: E402

for _v in _idle.THREADS:
    os.environ.setdefault(_v, "1")
try:
    import numpy as np
except ImportError:
    np = None

from orpheusd import dropmap as dm  # noqa: E402

REPO = Path(__file__).resolve().parent.parent
SR = 22050


def _kick(n, amp):
    t = np.arange(int(0.25 * SR)) / SR
    k = np.sin(2 * np.pi * 55 * t) * np.exp(-t / 0.08) * amp
    return k[:n]


def _hat(rng, amp):
    h = np.diff(rng.standard_normal(int(0.03 * SR) + 1)) * np.exp(-np.arange(int(0.03 * SR)) / (0.008 * SR))
    return h * amp * 0.25


class Track:
    """A signal of `seconds` you add events to at exact times."""

    def __init__(self, seconds, seed=1):
        self.x = np.zeros(int(seconds * SR))
        self.rng = np.random.default_rng(seed)

    def add(self, t, sig):
        i = int(round(t * SR))
        n = min(sig.size, self.x.size - i)
        if n > 0:
            self.x[i:i + n] += sig[:n]

    def sub(self, t0, t1, amp, hz=41.0):
        i0, i1 = int(t0 * SR), int(t1 * SR)
        t = np.arange(i1 - i0) / SR
        self.x[i0:i1] += amp * np.sin(2 * np.pi * hz * t)

    def riser(self, t0, t1, amp):
        i0, i1 = int(t0 * SR), int(t1 * SR)
        ramp = np.linspace(0, 1, i1 - i0) ** 2
        self.x[i0:i1] += np.diff(self.rng.standard_normal(i1 - i0 + 1)) * ramp * amp

    def groove(self, t0, t1, per, kick=0.5, sub=0.25, hats=2):
        t = t0
        while t < t1 - 1e-9:
            if kick:
                self.add(t, _kick(int(0.25 * SR), kick))
            for h in range(hats):
                self.add(t + h * per / hats, _hat(self.rng, 1.0))
            t += per
        if sub:
            self.sub(t0, t1, sub)

    def signal(self):
        return np.clip(self.x / max(1.0, np.abs(self.x).max() / 0.9), -1, 1)


def edm_120():
    """60 s at 120 BPM: groove, bars 10-13 (20-28 s) a build (no kick or sub,
    double hats, a riser), and at 28.0 s the kick and sub back at +9 dB."""
    tr, per = Track(60), 0.5
    tr.groove(0, 20, per)
    tr.groove(20, 28, per, kick=0, sub=0, hats=4)
    tr.riser(20, 28, 0.08)
    g = 10 ** (9 / 20)
    tr.groove(28, 60, per, kick=0.5 * g, sub=0.25 * g)
    return tr.signal()


@unittest.skipUnless(np is not None, "numpy missing")
class AnalyseTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.edm = edm_120()
        cls.m = dm.analyse(dm.features(cls.edm), 60)

    def test_a_drop_on_the_bar(self):
        m = self.m
        self.assertEqual(m["state"], "ready")
        self.assertLess(abs(m["bpm"] / 120 - 1), 0.01, m["bpm"])
        self.assertEqual(len(m["drops"]), 1, m["drops"])
        d = m["drops"][0]
        self.assertLess(abs(d["t"] - 28.0), 0.06, d)
        self.assertIn(d["t"], m["bars"])
        self.assertEqual(d["kind"], "return")
        self.assertEqual(m["builds"][0]["peak"], d["t"])
        self.assertLessEqual(m["builds"][0]["start"], 22)
        codes = [(s["start"], s["end"], s["code"]) for s in m["sections"]]
        self.assertTrue(any(c == 1 and e <= d["t"] + 1e-6 for s, e, c in codes), codes)
        self.assertTrue(any(c == 2 and abs(s - d["t"]) < 1e-6 for s, e, c in codes), codes)
        self.assertEqual(m["sections"][0]["start"], 0.0)
        self.assertEqual(m["sections"][-1]["end"], m["duration"])
        for a, b in zip(m["sections"], m["sections"][1:]):
            self.assertEqual(a["end"], b["start"])
        self.assertEqual(len(m["energy"]), 60)
        self.assertGreaterEqual(m["confidence"], 0.5)
        self.assertEqual(len(m["strength"]), len(m["beats"]))
        self.assertTrue(set(m["bars"]) <= set(m["beats"]))
        self.assertNotIn("source", json.dumps(m))

    def test_b_riff_is_not_a_drop_every_other_bar(self):
        per = 60 / 164
        bar = 4 * per
        tr = Track(32 * bar + 1, seed=2)
        tr.groove(0, 8 * bar, per)
        tr.groove(8 * bar, 16 * bar, per, kick=0, sub=0, hats=4)
        tr.riser(8 * bar, 16 * bar, 0.08)
        g = 10 ** (9 / 20)
        for b in range(16, 32):
            tr.groove(b * bar, (b + 1) * bar, per, kick=0.5 * g, sub=(0.25 * g if b % 2 == 0 else 0))
        m = dm.analyse(dm.features(tr.signal()), 32 * bar + 1, 164)
        self.assertEqual(len(m["drops"]), 1, m["drops"])
        self.assertLess(abs(m["drops"][0]["t"] - 16 * bar), 0.06)

    def test_c_steady_silent_short(self):
        tr = Track(40, seed=3)
        tr.groove(0, 40, 0.5)
        self.assertEqual(dm.analyse(dm.features(tr.signal()), 40)["drops"], [])
        m = dm.analyse(dm.features(np.zeros(30 * SR)), 30)
        self.assertEqual(m["drops"], [])
        self.assertLess(m["confidence"], 0.5)
        self.assertTrue(all(v == 0 for v in m["energy"]))
        short = Track(8, seed=4)
        short.groove(0, 8, 0.5)
        m = dm.analyse(dm.features(short.signal()), 8)
        self.assertEqual(m["state"], "ready")
        self.assertEqual(m["drops"], [])

    def test_d_chunking_does_not_change_frames(self):
        n = dm.N_FFT + 2048 * dm.HOP                    # exactly 2049 frames
        x = (np.random.default_rng(5).standard_normal(n) * 0.2).clip(-1, 1)
        a = dm.features(x)
        self.assertEqual(a.env.size, 2049)
        raw = np.round(x * 32767).astype("<i2").tobytes()

        class Odd(io.BytesIO):          # short reads at odd sizes, odd byte counts included
            sizes = [7777, 12345, 1, 99999, 3]

            def read(self, k=-1):
                self.sizes = self.sizes[1:] + self.sizes[:1]
                return super().read(min(k, self.sizes[0]) if k > 0 else self.sizes[0])
        b = dm.feed(Odd(raw))
        self.assertEqual(b.n_samples, n)
        for k in ("env", "lenv", "sub", "hi", "tot", "rms_s"):
            self.assertTrue(np.allclose(getattr(a, k), getattr(b, k), rtol=1e-4, atol=1e-6), k)

    def test_e_octave_snap(self):
        per = 60 / 82
        tr = Track(40, seed=6)
        t = 0.0
        while t < 40:
            tr.add(t, _kick(int(0.25 * SR), 0.8))
            t += per
        f = dm.features(tr.signal())
        bpm, _, lag = dm.tempo(f.env, f.fr)
        self.assertLess(abs(bpm / 82 - 1), 0.01, bpm)
        bpm, _, lag2 = dm.tempo(f.env, f.fr, 164)
        self.assertLess(abs(bpm / 164 - 1), 0.01, bpm)
        self.assertAlmostEqual(lag2 * 2, lag, places=4)

    def test_f_redact_and_argv(self):
        self.assertEqual(dm.redact("403 on https://sp.tidal.com/a?token=x and http://b/c"), "403 on <url> and <url>")
        base = ["ff", "-nostdin", "-hide_banner", "-loglevel", "error", "-threads", "1", "-rw_timeout", "20000000"]
        tail = ["-t", "1200", "-i", "src", "-vn", "-map", "a:0", "-ac", "1", "-ar", "22050", "-f", "s16le", "pipe:1"]
        self.assertEqual(dm.ffmpeg_cmd("ff", "src", False, 1200), base + tail)
        self.assertEqual(dm.ffmpeg_cmd("ff", "src", True, 1200),
                         base + ["-protocol_whitelist", "file,http,https,tcp,tls,crypto,data"] + tail)


@unittest.skipUnless(np is not None, "numpy missing")
class WorkerTest(unittest.TestCase):
    def test_g_worker(self):
        with tempfile.TemporaryDirectory() as tmp:
            pcm = Path(tmp) / "t.pcm"
            pcm.write_bytes(np.round(edm_120() * 32767).astype("<i2").tobytes())
            job = json.dumps({"pcm": str(pcm), "duration": 60, "bpm": 120}) + "\n"
            p = _idle.run([sys.executable, "-m", "orpheusd.dropmap"], input=job.encode(), cwd=str(REPO))
            self.assertEqual(p.returncode, 0, p.stderr[-400:])
            m = json.loads(p.stdout)
            self.assertEqual(m["state"], "ready")
            self.assertEqual(len(m["drops"]), 1)
        p = _idle.run([sys.executable, "-m", "orpheusd.dropmap"], input=b"{}\n", cwd=str(REPO))
        self.assertEqual(p.returncode, 4)
        self.assertEqual(json.loads(p.stdout)["state"], "failed")

    def test_g_numpy_missing(self):
        saved, out = dm.np, io.StringIO()
        try:
            dm.np = None
            with contextlib.redirect_stdout(out), unittest.mock.patch("sys.stdin", io.StringIO('{"pcm": "x", "duration": 5}\n')):
                rc = dm.main()
        finally:
            dm.np = saved
        self.assertEqual(rc, 3)
        self.assertEqual(json.loads(out.getvalue()), {"state": "failed", "error": "numpy missing"})


if __name__ == "__main__":
    unittest.main()
