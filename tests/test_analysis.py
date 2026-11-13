"""The drop-map manager (orpheusd/analysis.py) with a fake worker.

The fake reads the job line, sleeps (the track's `bpm` field, in seconds, so a
test can hold a job open), and prints a canned map, or a failure. Everything
lives in a temp dir; no daemon, no ffmpeg, no network.
"""
import asyncio
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from aiohttp import web
from aiohttp.test_utils import TestClient, TestServer

from orpheusd import analysis as an
from orpheusd.config import Config

FAKE = r"""
import json, sys, time
job = json.loads(sys.stdin.readline())
time.sleep(job.get("bpm") or 0.3)
print(json.dumps({"state": "ready", "duration": job["duration"] - 0.3, "bpm": 120.0, "confidence": 0.9,
                  "beats": [0.5, 1.0], "strength": [1, 1], "bars": [0.5], "drops": [{"t": 28.0, "strength": 0.8, "kind": "return"}],
                  "builds": [], "sections": [{"start": 0, "end": job["duration"], "code": 4}], "energy": [],
                  "seen": job["source"].endswith(".mpd") and __import__("os").path.exists(job["source"])}))
"""
FAIL = r"""
import json, sys
sys.stdin.readline()
print(json.dumps({"state": "failed", "error": "403 for https://sp.example/x?token=1"}))
sys.exit(2)
"""


def track(i="101", dur=60, **kw):
    return dict({"id": i, "duration": dur, "title": "t"}, **kw)


class AnalysisTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.tmpd = tempfile.TemporaryDirectory()
        self.tmp = Path(self.tmpd.name)
        self.cfg_path = self.tmp / "config.json"
        self.changes = 0
        self.spawns = []
        real = asyncio.create_subprocess_exec

        async def spy(*a, **kw):
            self.spawns.append((a, kw))
            return await real(*a, **kw)
        self.patch = mock.patch("asyncio.create_subprocess_exec", spy)
        self.patch.start()
        self.a = self.make(FAKE)

    def make(self, code, ffmpeg="C:/fake/ffmpeg"):
        def bump():
            self.changes += 1
        return an.Analysis(self.tmp / "cache", self.tmp / "run", Config(self.cfg_path), bump,
                           worker_cmd=[sys.executable, "-c", code], ffmpeg=ffmpeg)

    async def asyncTearDown(self):
        await self.a.close()
        self.patch.stop()
        self.tmpd.cleanup()

    async def until(self, cond, timeout=15):
        t = asyncio.get_running_loop().time()
        while not cond():
            if asyncio.get_running_loop().time() - t > timeout:
                self.fail("timed out")
            await asyncio.sleep(0.05)

    def bts(self, url="https://sp.example/a.flac?token=1"):
        return {"source": url, "dash": False}

    async def test_schedule_runs_caches_and_hits(self):
        t = track()
        v0 = self.a.version
        self.a.schedule(t, self.bts(), "current")
        self.assertEqual(self.a.state()["state"], "pending")
        self.assertGreater(self.a.version, v0)
        self.assertGreater(self.changes, 0)
        await self.until(lambda: self.a.state()["state"] == "ready")
        key = an.key_of(t)
        self.assertEqual(key, "tidal_101_60")
        data = json.loads((self.tmp / "cache" / "analysis" / f"{key}.json").read_text())
        self.assertEqual(data["v"], an.MAP_V)
        self.assertEqual((data["key"], data["id"], data["provider"]), (key, "101", "tidal"))
        self.assertNotIn("token", json.dumps(data))
        got = await self.a.get("101", "tidal", 60.4)
        self.assertEqual(got["state"], "ready")
        n = len(self.spawns)
        self.a.schedule(t, self.bts(), "current")
        await asyncio.sleep(0.2)
        self.assertEqual(len(self.spawns), n)
        self.assertEqual(self.a.state()["state"], "ready")

    async def test_spawn_is_idle_windowless_one_thread(self):
        self.a.schedule(track(), self.bts(), "current")
        await self.until(lambda: self.spawns)
        a, kw = self.spawns[0]
        self.assertEqual(kw["env"]["OPENBLAS_NUM_THREADS"], "1")
        self.assertNotIn("preexec_fn", kw)
        if sys.platform == "win32":
            self.assertTrue(kw["creationflags"] & 0x08000000)
            self.assertTrue(kw["creationflags"] & 0x40)
        self.assertNotIn("https://sp.example/a.flac?token=1", " ".join(map(str, a)))   # the source goes on stdin only

    async def test_retarget_kills(self):
        t = track(bpm=8)
        self.a.schedule(t, self.bts(), "current")
        await self.until(lambda: self.a._running and self.a._running.proc)
        proc = self.a._running.proc
        self.a.retarget("tidal_999_60", None)
        await self.until(lambda: proc.returncode is not None, 5)
        await self.until(lambda: self.a._running is None, 5)
        self.assertFalse((self.tmp / "cache" / "analysis" / "tidal_101_60.json").exists())
        self.assertNotEqual(self.a._state.get("tidal_101_60"), "ready")

    async def test_current_preempts(self):
        self.a.schedule(track("1", bpm=8), self.bts(), "current")
        await self.until(lambda: self.a._running and self.a._running.proc)
        first = self.a._running.proc
        self.a.schedule(track("2"), self.bts(), "current")
        await self.until(lambda: first.returncode is not None, 5)
        await self.until(lambda: self.a.state()["state"] == "ready")
        self.assertEqual(self.a.state()["key"], "tidal_2_60")
        self.assertFalse((self.tmp / "cache" / "analysis" / "tidal_1_60.json").exists())

    async def test_retarget_follows_a_gapless_move(self):
        self.a.retarget("tidal_1_60", "tidal_2_60")
        self.a.schedule(track("2", bpm=0.5), self.bts(), "next")
        v = self.a.version
        self.a.retarget("tidal_2_60", None)        # start-file / crossfade promotion: no _load
        self.assertEqual(self.a.state()["key"], "tidal_2_60")
        self.assertGreater(self.a.version, v)
        await self.until(lambda: self.a.state()["state"] == "ready")

    async def test_back_to_a_cancelled_key_requeues(self):
        self.a.schedule(track("1", bpm=8), self.bts(), "current")
        await self.until(lambda: self.a._running and self.a._running.proc)
        self.a.retarget("tidal_9_60", None)        # killed, not yet reaped
        self.a.retarget("tidal_1_60", None)
        self.a.schedule(track("1", bpm=0.2), self.bts(), "current")
        self.assertEqual(self.a._state.get("tidal_1_60"), "pending")
        await self.until(lambda: self.a.state()["state"] == "ready")

    async def test_next_survives_current(self):
        self.a.retarget("tidal_1_60", "tidal_2_60")
        self.a.schedule(track("2", bpm=1.0), self.bts(), "next")
        await self.until(lambda: self.a._running and self.a._running.proc)
        self.a.schedule(track("1"), self.bts(), "current")
        await self.until(lambda: self.a._state.get("tidal_1_60") == "ready" and self.a._state.get("tidal_2_60") == "ready")

    async def test_skip_reasons(self):
        cases = [(track(provider="youtube"), "provider"), (track(live=True), "live"),
                 (track(dur=0), None), (track(dur=1300), "long")]
        for t, why in cases:
            self.a.schedule(t, self.bts(), "current")
            if why:
                k = an.key_of(t)
                self.assertEqual((self.a._state[k], self.a._reason[k]), ("none", why), t)
        self.assertEqual(self.a.skip_reason(track(dur=0)), "nodur")
        # Navidrome streams are stable with exact durations: analysed like TIDAL's.
        self.assertIsNone(self.a.skip_reason(track(provider="navidrome")))
        self.assertEqual(self.a.skip_reason(track(provider="soundcloud")), "provider")
        self.assertEqual(self.make(FAKE, ffmpeg=None).skip_reason(track()), "unavailable")
        self.cfg_path.write_text(json.dumps({"dropMap": False}))
        self.a.config.refresh(force=True)
        self.assertEqual(self.a.skip_reason(track()), "off")
        self.a.schedule(track("5"), self.bts(), "current")
        self.assertEqual(self.a.state()["state"], "none")
        self.assertEqual((await self.a.get("5", "tidal", 60))["reason"], "off")
        self.assertEqual(self.spawns, [])

    async def test_failure_backoff(self):
        await self.a.close()
        self.a = self.make(FAIL)
        self.a.schedule(track(), self.bts(), "current")
        await self.until(lambda: self.a.state()["state"] == "failed")
        st = self.a.state()
        self.assertNotIn("https://", st["error"])
        self.assertIn("<url>", st["error"])
        self.assertFalse(list((self.tmp / "cache" / "analysis").glob("*.json")))
        n = len(self.spawns)
        self.a.schedule(track(), self.bts(), "current")
        await asyncio.sleep(0.2)
        self.assertEqual(len(self.spawns), n)
        self.assertEqual((await self.a.get("101", "tidal", 60))["state"], "failed")
        self.a.schedule(track(), self.bts("https://sp.example/fresh"), "current")   # a fresh source retries now
        await self.until(lambda: len(self.spawns) > n)

    async def test_duration_mismatch_fails(self):
        await self.a.close()
        self.a = self.make(FAKE.replace('job["duration"] - 0.3', "30.0"))
        self.a.schedule(track(), self.bts(), "current")
        await self.until(lambda: self.a.state()["state"] == "failed")
        self.assertEqual(self.a.state()["error"], "duration mismatch")

    async def test_state_shape(self):
        st = self.a.state()
        self.assertEqual(set(st), {"on", "available", "ffmpeg", "numpy", "key", "state", "version", "queued", "lastMs", "error"})
        self.assertLess(len(json.dumps(st)), 200)

    async def test_dash_copy_lives_for_the_job(self):
        mpd = self.tmp / "101.mpd"
        mpd.write_text("<MPD>https://sp.example/seg</MPD>")
        self.a.schedule(track(), {"source": str(mpd), "dash": True}, "current")
        copies = list((self.tmp / "run" / "analysis").glob("tidal_101_60-*.mpd"))
        self.assertEqual(len(copies), 1)
        copy = copies[0]
        await self.until(lambda: self.a.state()["state"] == "ready")
        self.assertFalse(copy.exists())
        data = json.loads((self.tmp / "cache" / "analysis" / "tidal_101_60.json").read_text())
        self.assertTrue(data["seen"])
        self.assertNotIn("sp.example", json.dumps(data))

    async def test_route(self):
        a = self.a

        async def route(req):          # orpheusd/__main__.py's /analysis/{id}, minus the queue lookup
            q = req.query
            try:
                duration = float(q.get("duration") or 0)
            except ValueError:
                duration = 0
            if duration <= 0:
                raise web.HTTPNotFound(text="unknown track")
            return web.json_response(await a.get(req.match_info["id"], q.get("provider") or "tidal", duration))
        app = web.Application()
        app.router.add_get("/analysis/{id}", route)
        client = TestClient(TestServer(app))
        await client.start_server()
        try:
            a.schedule(track(), self.bts(), "current")
            r = await client.get("/analysis/101?provider=tidal&duration=60")
            self.assertEqual((r.status, (await r.json())["state"]), (200, "pending"))
            await self.until(lambda: a.state()["state"] == "ready")
            r = await client.get("/analysis/101?provider=tidal&duration=60")
            self.assertEqual((await r.json())["state"], "ready")
            r = await client.get("/analysis/101")
            self.assertEqual(r.status, 404)
        finally:
            await client.close()

    async def test_close_kills(self):
        self.a.schedule(track(bpm=8), self.bts(), "current")
        await self.until(lambda: self.a._running and self.a._running.proc)
        proc = self.a._running.proc
        await self.a.close()
        await self.until(lambda: proc.returncode is not None, 5)


if __name__ == "__main__":
    unittest.main()
