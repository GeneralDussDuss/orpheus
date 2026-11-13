"""orpheusd/navidrome.py against a fake Subsonic server: auth, mapping,
streams, errors, scrobbles, the search merge and the provider scrobble route."""
import asyncio
import hashlib
import unittest
from urllib.parse import parse_qs, urlparse

from aiohttp import web
from aiohttp.test_utils import TestServer

from orpheusd.navidrome import Navidrome, NavidromeError, merge_search, route_scrobble, search_all

SONG = {"id": "s1", "title": "Ferryman", "artist": "Styx Crew", "artistId": "a1",
        "album": "Across", "albumId": "al1", "duration": 212, "suffix": "flac",
        "bitRate": 1024, "coverArt": "c1"}
ALBUM = {"id": "al1", "name": "Across", "artist": "Styx Crew", "artistId": "a1",
         "year": 2024, "coverArt": "c2"}
ARTIST = {"id": "a1", "name": "Styx Crew", "coverArt": "c3"}


def ok(payload):
    return {"subsonic-response": dict({"status": "ok", "version": "1.16.1"}, **payload)}


class FakeSubsonic:
    """Records every /rest call and answers canned JSON."""

    def __init__(self):
        self.calls = []            # (endpoint, {param: [values]})
        self.fail = None           # (code, message) -> every endpoint fails
        self.scrobble_status = 200
        app = web.Application()
        app.router.add_get("/rest/{endpoint}", self.handle)
        self.server = TestServer(app)

    async def handle(self, req):
        endpoint = req.match_info["endpoint"].replace(".view", "")
        self.calls.append((endpoint, {k: req.query.getall(k) for k in req.query}))
        if self.fail:
            code, msg = self.fail
            return web.json_response({"subsonic-response": {
                "status": "failed", "version": "1.16.1",
                "error": {"code": code, "message": msg}}})
        if endpoint == "ping":
            return web.json_response(ok({}))
        if endpoint == "search3":
            return web.json_response(ok({"searchResult3": {
                "song": [SONG], "album": [ALBUM], "artist": [ARTIST]}}))
        if endpoint == "getAlbum":
            return web.json_response(ok({"album": dict(ALBUM, song=[SONG])}))
        if endpoint == "getArtist":
            return web.json_response(ok({"artist": dict(ARTIST, album=[ALBUM])}))
        if endpoint == "getSong":
            return web.json_response(ok({"song": SONG}))
        if endpoint == "scrobble":
            if self.scrobble_status != 200:
                return web.Response(status=self.scrobble_status)
            return web.json_response(ok({}))
        return web.json_response(ok({}))

    def last(self, endpoint):
        for ep, q in reversed(self.calls):
            if ep == endpoint:
                return q
        return None


class NavidromeTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.fake = FakeSubsonic()
        await self.fake.server.start_server()
        self.base = str(self.fake.server.make_url(""))
        self.nd = Navidrome(self.base, "ferry", "pw")

    async def asyncTearDown(self):
        await self.nd.close()
        await self.fake.server.close()

    # ---- auth and plumbing ---------------------------------------------------

    async def test_auth_params_and_token(self):
        self.assertTrue(await self.nd.ping())
        q = self.fake.last("ping")
        self.assertEqual(q["u"], ["ferry"])
        self.assertEqual(q["v"], ["1.16.1"])
        self.assertEqual(q["c"], ["Orpheus"])
        self.assertEqual(q["f"], ["json"])
        salt = q["s"][0]
        self.assertGreaterEqual(len(salt), 8)
        self.assertEqual(q["t"][0], hashlib.md5(("pw" + salt).encode()).hexdigest())

    async def test_fresh_salt_per_request(self):
        nd = Navidrome(self.base, "ferry", "pw")
        await nd.search("a")
        await nd.search("b")
        await nd.close()
        salts = [q["s"][0] for ep, q in self.fake.calls if ep == "search3"]
        self.assertEqual(len(salts), 2)
        self.assertNotEqual(salts[0], salts[1])

    async def test_url_normalized(self):
        for suffix in ("/", "/rest", "/rest/"):
            nd = Navidrome(self.base.rstrip("/") + suffix, "u", "p")
            self.assertTrue(await nd.ping(), suffix)
            await nd.close()

    async def test_unavailable_when_blank(self):
        for url, user, pw in (("", "u", "p"), (self.base, " ", "p"), (self.base, "u", "")):
            self.assertFalse(Navidrome(url, user, pw).available)
        self.assertTrue(self.nd.available)

    async def test_unicode_password_and_query(self):
        nd = Navidrome(self.base, "ferry", "mötley·pass")
        out = await nd.search("naïve crüe")
        q = self.fake.last("search3")
        self.assertEqual(q["query"], ["naïve crüe"])
        salt = q["s"][0]
        self.assertEqual(q["t"][0], hashlib.md5(("mötley·pass" + salt).encode()).hexdigest())
        self.assertEqual(len(out["tracks"]), 1)
        await nd.close()

    # ---- mapping ---------------------------------------------------------------

    async def test_search_maps_and_tags(self):
        out = await self.nd.search("ferry")
        t = out["tracks"][0]
        self.assertEqual((t["kind"], t["provider"], t["id"], t["title"]), ("track", "navidrome", "s1", "Ferryman"))
        self.assertEqual(t["artist"], "Styx Crew")
        self.assertEqual(t["artists"], ["Styx Crew"])
        self.assertEqual((t["album"], t["albumId"], t["duration"]), ("Across", "al1", 212))
        self.assertFalse(t["hires"])
        a = out["albums"][0]
        self.assertEqual((a["kind"], a["provider"], a["title"], a["artistId"], a["year"]),
                         ("album", "navidrome", "Across", "a1", 2024))
        ar = out["artists"][0]
        self.assertEqual((ar["kind"], ar["provider"], ar["name"]), ("artist", "navidrome", "Styx Crew"))
        self.assertEqual(out["playlists"], [])

    async def test_cover_url_carries_auth(self):
        t = (await self.nd.search("x"))["tracks"][0]
        q = parse_qs(urlparse(t["cover"]).query)
        self.assertEqual(q["id"], ["c1"])
        self.assertIn("t", q)
        self.assertIn("s", q)
        self.assertIn("/rest/getCoverArt", t["cover"])

    async def test_album_and_artist_shapes(self):
        al = await self.nd.album("al1")
        self.assertEqual(al["album"]["id"], "al1")
        self.assertEqual([t["id"] for t in al["tracks"]], ["s1"])
        self.assertEqual(al["tracks"][0]["provider"], "navidrome")
        ar = await self.nd.artist("a1")
        self.assertEqual(ar["artist"]["name"], "Styx Crew")
        self.assertEqual([a["id"] for a in ar["albums"]], ["al1"])

    # ---- stream ----------------------------------------------------------------

    async def test_stream_url_and_quality(self):
        s = await self.nd.stream("s1")
        self.assertIn("/rest/stream", s["url"])
        q = parse_qs(urlparse(s["url"]).query)
        self.assertEqual(q["id"], ["s1"])
        self.assertEqual(q["format"], ["raw"])
        self.assertIn("t", q)
        self.assertEqual(s["quality"], "LOSSLESS")
        self.assertEqual(s["codec"], "flac")
        self.nd.forget("s1")   # a no-op, but part of the source surface

    # ---- failure ---------------------------------------------------------------

    async def test_error_status_raises_but_ping_degrades(self):
        self.fake.fail = (40, "Wrong username or password.")
        with self.assertRaises(NavidromeError) as cm:
            await self.nd.search("x")
        self.assertIn("Wrong username", str(cm.exception))
        nd2 = Navidrome(self.base, "ferry", "bad")
        self.assertFalse(await nd2.ping())
        await nd2.close()

    async def test_scrobble_swallows_and_submits(self):
        await self.nd.scrobble("s1", True)
        q = self.fake.last("scrobble")
        self.assertEqual(q["id"], ["s1"])
        self.assertEqual(q["submission"], ["true"])
        self.fake.scrobble_status = 500
        await self.nd.scrobble("s1", False)    # must not raise
        self.assertEqual(self.fake.last("scrobble")["submission"], ["false"])


class MergeAndRoutingTest(unittest.IsolatedAsyncioTestCase):
    def test_merge_search(self):
        base = {"tracks": [1], "albums": [2], "artists": [3], "playlists": [9]}
        extra = {"tracks": [4], "albums": [5], "artists": [6], "playlists": []}
        out = merge_search(base, extra)
        self.assertEqual(out["tracks"], [1, 4])
        self.assertEqual(out["albums"], [2, 5])
        self.assertEqual(out["artists"], [3, 6])
        self.assertEqual(out["playlists"], [9])
        self.assertEqual(merge_search({}, {"tracks": [7]})["tracks"], [7])

    async def test_search_degrades_per_side(self):
        class FakeND:
            available = True
            async def search(self, q):
                return {"tracks": ["nd"], "albums": [], "artists": [], "playlists": []}
        class FailND:
            available = True
            async def search(self, q):
                raise NavidromeError("down")

        async def tidal_ok(q):
            return {"tracks": ["td"], "albums": [], "artists": [], "playlists": []}
        async def tidal_boom(q):
            raise RuntimeError("tidal down")

        out = await search_all(tidal_ok, FakeND(), "x")
        self.assertEqual(out["tracks"], ["td", "nd"])
        out = await search_all(tidal_boom, FakeND(), "x")
        self.assertEqual(out["tracks"], ["nd"])
        out = await search_all(None, FakeND(), "x")      # signed out: navidrome alone
        self.assertEqual(out["tracks"], ["nd"])
        out = await search_all(tidal_ok, FailND(), "x")
        self.assertEqual(out["tracks"], ["td"])

    async def test_route_scrobble(self):
        sent, fell = [], []
        class FakeND:
            available = True
            async def scrobble(self, tid, submission):
                sent.append((tid, submission))
        def fallback(track, *a):
            fell.append(track)

        nd = FakeND()
        route_scrobble(nd, fallback, {"provider": "navidrome", "id": "s1"}, submission=True)
        await asyncio.sleep(0.05)
        self.assertEqual(sent, [("s1", True)])
        self.assertEqual(fell, [])
        route_scrobble(nd, fallback, {"id": "t1", "title": "x"}, submission=True)
        self.assertEqual([t["id"] for t in fell], ["t1"])
        nd.available = False
        route_scrobble(nd, fallback, {"provider": "navidrome", "id": "s2"}, submission=False)
        self.assertEqual(len(fell), 2)


class PlayerResolveTest(unittest.IsolatedAsyncioTestCase):
    async def test_player_resolves_navidrome_without_tidal(self):
        from orpheusd.player import Player

        class Boom:
            async def stream(self, *a, **k):
                raise AssertionError("tidal must not be touched")

        class Src:
            async def stream(self, tid):
                return {"url": "http://nd/rest/stream?id=" + tid, "quality": "LOSSLESS"}

        import tempfile
        from pathlib import Path
        with tempfile.TemporaryDirectory() as tmp:
            p = Player(Boom(), {"navidrome": Src()}, Path(tmp), Path(tmp), on_change=lambda: None)
            info = await p._resolve({"provider": "navidrome", "id": "s1"})
            self.assertEqual(info["quality"], "LOSSLESS")


if __name__ == "__main__":
    unittest.main()
