"""GET /queue and Player.queue_window / queue_rev: the cassette deck's j-card."""
import unittest
from types import SimpleNamespace

from aiohttp import web
from aiohttp.test_utils import TestClient, TestServer

from orpheusd.__main__ import guard_middleware
from orpheusd.player import Player


def track(n, **extra):
    t = {"id": n, "title": f"t{n}", "artists": [f"a{n}"], "album": "al", "duration": 180 + n,
         "kind": "track", "explicit": False, "art": f"https://img/{n}.jpg", "source": {"x": 1}}
    t.update(extra)
    return t


def fake(n=10, order=None, pos=0, shuffle=False):
    p = SimpleNamespace(queue=[track(i) for i in range(n)], pos=pos, context={"title": "mix"}, shuffle=shuffle,
                        QUEUE_FIELDS=Player.QUEUE_FIELDS)
    p.order = order if order is not None else list(range(n))
    p.queue_rev = lambda: Player.queue_rev(p)
    p.queue_window = lambda start, count: Player.queue_window(p, start, count)
    return p


class QueueWindowTest(unittest.TestCase):
    def test_slice_in_play_order(self):
        p = fake(6, order=[3, 0, 5, 1, 4, 2], pos=2)
        w = p.queue_window(1, 3)
        self.assertEqual([r["id"] for r in w["tracks"]], [0, 5, 1])
        self.assertEqual([r["i"] for r in w["tracks"]], [1, 2, 3])
        self.assertEqual((w["index"], w["length"], w["from"]), (2, 6, 1))
        self.assertEqual(w["context"], {"title": "mix"})
        self.assertEqual(w["queueRev"], p.queue_rev())

    def test_clamps(self):
        p = fake(10)
        self.assertEqual(p.queue_window(-5, 2)["from"], 0)
        w = p.queue_window(50, 5)
        self.assertEqual((w["from"], w["tracks"]), (10, []))
        big = fake(300)
        self.assertEqual(len(big.queue_window(0, 500)["tracks"]), 100)
        self.assertEqual(len(p.queue_window(8, 5)["tracks"]), 2)
        self.assertEqual(p.queue_window(0, 0)["tracks"], [])

    def test_rows_carry_no_art(self):
        for r in fake(5).queue_window(0, 5)["tracks"]:
            self.assertNotIn("art", r)
            self.assertNotIn("source", r)
            self.assertEqual(set(r) - {"i"}, set(Player.QUEUE_FIELDS))

    def test_rev(self):
        p = fake(10)
        r0 = p.queue_rev()
        p.pos = 4
        self.assertEqual(p.queue_rev(), r0)               # a skip is not a queue edit
        p.order = list(p.order)
        self.assertNotEqual(p.queue_rev(), r0)            # shuffle replaces the order
        r1 = p.queue_rev()
        p.queue = p.queue + [track(99)]
        self.assertNotEqual(p.queue_rev(), r1)            # enqueue
        r2 = p.queue_rev()
        p.shuffle = True
        self.assertNotEqual(p.queue_rev(), r2)
        self.assertRegex(p.queue_rev(), r"^[0-9a-f]{8}$")


class QueueRouteTest(unittest.IsolatedAsyncioTestCase):
    """The route as orpheusd/__main__.py registers it, on a stub app."""

    async def asyncSetUp(self):
        player = fake(10, pos=4)

        async def queue(req):
            try:
                start = int(req.query.get("from", 0)); count = int(req.query.get("count", 40))
            except ValueError:
                raise web.HTTPBadRequest(text="from and count must be integers")
            return web.json_response(player.queue_window(start, count))

        app = web.Application(middlewares=[guard_middleware])
        app.router.add_get("/queue", queue)
        self.client = TestClient(TestServer(app))
        await self.client.start_server()

    async def asyncTearDown(self):
        await self.client.close()

    async def test_window(self):
        r = await self.client.get("/queue?from=1&count=2")
        self.assertEqual(r.status, 200)
        d = await r.json()
        self.assertEqual([t["i"] for t in d["tracks"]], [1, 2])
        self.assertEqual(d["index"], 4)

    async def test_bad_args(self):
        self.assertEqual((await self.client.get("/queue?from=x")).status, 400)
        self.assertEqual((await self.client.get("/queue?count=1.5")).status, 400)


if __name__ == "__main__":
    unittest.main()
