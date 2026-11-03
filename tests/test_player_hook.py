"""Player.on_resolved: the drop map hears about each fresh resolve exactly when
the player still wants it (orpheusd/player.py). mpv is stubbed out entirely."""
import tempfile
import unittest
from pathlib import Path

from orpheusd.player import Player


class Tidal:
    def __init__(self):
        self.calls = 0
        self.during = None          # runs inside stream(), e.g. to make the resolve stale

    async def stream(self, tid, cache_dir):
        self.calls += 1
        if self.during:
            self.during()
        return {"source": f"{tid}.mpd", "dash": True, "quality": "HI_RES_LOSSLESS"}


class PlayerHookTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.tmpd = tempfile.TemporaryDirectory()
        tmp = Path(self.tmpd.name)
        self.tidal = Tidal()
        self.seen = []
        self.p = Player(self.tidal, {}, tmp, tmp, lambda: None,
                        on_resolved=lambda t, info, role: self.seen.append((t["id"], info["source"], role)))
        self.sent = []

        async def send(cmd, wait=True, deck=None):
            self.sent.append(cmd)
            return {"playlist_entry_id": 1} if cmd and cmd[0] == "loadfile" else None

        async def nothing(*a, **k):
            return ""
        self.p._send = send
        self.p._cover = nothing
        self.p._cancel_xfade = nothing
        self.p._heap_mb = lambda: 0
        self.p._xfade_ok = lambda nxt: False
        self.p.queue = [{"id": "a", "duration": 200}, {"id": "b", "duration": 180}]
        self.p.order = [0, 1]

    async def asyncTearDown(self):
        self.tmpd.cleanup()

    async def test_load_fires_current_once(self):
        await self.p._load(0)
        self.assertEqual(self.seen, [("a", "a.mpd", "current")])

    async def test_stale_load_fires_nothing(self):
        self.tidal.during = lambda: setattr(self.p, "_loading", self.p._loading + 1)
        await self.p._load(0)
        self.assertEqual(self.seen, [])

    async def test_prefetch_fires_next(self):
        await self.p._load(0)
        self.seen.clear()
        await self.p._prefetch_next()
        self.assertEqual(self.seen, [("b", "b.mpd", "next")])

    async def test_hook_errors_do_not_break_playback(self):
        def boom(*a):
            raise RuntimeError("x")
        self.p.on_resolved = boom
        await self.p._load(0)
        self.assertTrue(any(c[0] == "loadfile" for c in self.sent))


if __name__ == "__main__":
    unittest.main()
