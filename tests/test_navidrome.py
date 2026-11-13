"""orpheusd/navidrome.py against a fake Subsonic server: auth, mapping,
streams, errors, scrobbles, the search merge and the provider scrobble route."""
import asyncio
import hashlib
import unittest
from urllib.parse import parse_qs, urlparse

from aiohttp import web
from aiohttp.test_utils import TestServer

from orpheusd.navidrome import (Navidrome, NavidromeError, merge_search, route_scrobble,
                                search_all, tracks_for_navidrome)

SONG = {"id": "s1", "title": "Ferryman", "artist": "Styx Crew", "artistId": "a1",
        "album": "Across", "albumId": "al1", "duration": 212, "suffix": "flac",
        "bitRate": 1024, "coverArt": "c1"}
ALBUM = {"id": "al1", "name": "Across", "artist": "Styx Crew", "artistId": "a1",
         "year": 2024, "songCount": 1, "duration": 212, "coverArt": "c2"}
ARTIST = {"id": "a1", "name": "Styx Crew", "coverArt": "c3"}


def ok(payload):
    return {"subsonic-response": dict({"status": "ok", "version": "1.16.1"}, **payload)}


class FakeSubsonic:
    """Records every /rest call and answers canned JSON."""

    def __init__(self):
        self.calls = []            # (endpoint, {param: [values]})
        self.fail = None           # (code, message) -> every endpoint fails
        self.scrobble_status = 200
        self.delay = 0.0           # seconds each request sleeps first
        app = web.Application()
        app.router.add_get("/rest/{endpoint}", self.handle)
        self.server = TestServer(app)

    async def handle(self, req):
        endpoint = req.match_info["endpoint"].replace(".view", "")
        self.calls.append((endpoint, {k: req.query.getall(k) for k in req.query}))
        if self.delay:
            await asyncio.sleep(self.delay)
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
        if endpoint == "getTopSongs":
            return web.json_response(ok({"topSongs": {"song": [SONG]}}))
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

    async def test_search_maps_to_the_tidal_vocabulary(self):
        # The UI and daemon read tidal.py's field names: title, artists (a
        # list of names), artistId, art, hires, quality. Not cover/name/artist.
        out = await self.nd.search("ferry")
        t = out["tracks"][0]
        self.assertEqual((t["kind"], t["provider"], t["id"], t["title"]), ("track", "navidrome", "s1", "Ferryman"))
        self.assertEqual(t["artists"], ["Styx Crew"])
        self.assertEqual(t["artistId"], "a1")
        self.assertEqual((t["album"], t["albumId"], t["duration"]), ("Across", "al1", 212))
        self.assertFalse(t["hires"])
        self.assertFalse(t["explicit"])
        self.assertEqual(t["quality"], "LOSSLESS")
        self.assertIn("/rest/getCoverArt", t["art"])
        a = out["albums"][0]
        self.assertEqual((a["kind"], a["provider"], a["title"], a["artistId"]), ("album", "navidrome", "Across", "a1"))
        self.assertEqual(a["artists"], ["Styx Crew"])
        self.assertEqual((a["year"], a["tracks"]), ("2024", 1))
        self.assertIn("/rest/getCoverArt", a["art"])
        ar = out["artists"][0]
        self.assertEqual((ar["kind"], ar["provider"], ar["title"]), ("artist", "navidrome", "Styx Crew"))
        self.assertEqual(out["playlists"], [])
        self.assertIsNone(out["top"])

    async def test_cover_url_carries_auth(self):
        t = (await self.nd.search("x"))["tracks"][0]
        q = parse_qs(urlparse(t["art"]).query)
        self.assertEqual(q["id"], ["c1"])
        self.assertIn("t", q)
        self.assertIn("s", q)
        self.assertIn("/rest/getCoverArt", t["art"])

    async def test_album_and_artist_pages_are_flat_like_tidals(self):
        # Library reads pageData.title/.art/.artists/.items (and .albums/
        # .singles for artists) - tidal.py's album()/artist() shapes.
        al = await self.nd.album("al1")
        self.assertEqual((al["kind"], al["id"], al["title"]), ("album", "al1", "Across"))
        self.assertEqual(al["artists"], ["Styx Crew"])
        self.assertIn("/rest/getCoverArt", al["art"])
        self.assertEqual([t["id"] for t in al["items"]], ["s1"])
        self.assertEqual(al["items"][0]["provider"], "navidrome")
        ar = await self.nd.artist("a1")
        self.assertEqual((ar["kind"], ar["title"]), ("artist", "Styx Crew"))
        self.assertEqual([t["id"] for t in ar["items"]], ["s1"])     # top songs
        self.assertEqual([a["id"] for a in ar["albums"]], ["al1"])
        self.assertEqual(ar["singles"], [])

    # ---- stream ----------------------------------------------------------------

    async def test_stream_source_and_quality(self):
        # Player._load reads info["source"] (player.py:740), as tidal.py and
        # youtube.py both return; "url" never plays.
        s = await self.nd.stream("s1")
        self.assertIn("/rest/stream", s["source"])
        self.assertFalse(s["dash"])
        q = parse_qs(urlparse(s["source"]).query)
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


class ConfigBackedTest(unittest.IsolatedAsyncioTestCase):
    async def test_reads_config_live(self):
        class Cfg:
            def __init__(self):
                self.d = {}
            def text(self, k):
                return self.d.get(k, "")
        cfg = Cfg()
        nd = Navidrome.from_config(cfg)
        self.assertFalse(nd.available)
        fake = FakeSubsonic()
        await fake.server.start_server()
        cfg.d = {"navidromeUrl": str(fake.server.make_url("")) + "/",
                 "navidromeUser": "ferry", "navidromePass": "pw"}
        self.assertTrue(nd.available)          # picked up without a restart
        self.assertTrue(await nd.ping())
        q = fake.last("ping")
        self.assertEqual(q["u"], ["ferry"])
        await nd.close()
        await fake.server.close()


class MergeAndRoutingTest(unittest.IsolatedAsyncioTestCase):
    def test_merge_keeps_top_and_reserves_visible_slots(self):
        # Library shows only the first 10/8/6 of each list, and keeps the
        # "top" hit: the merge must leave both sides visible inside that
        # window and never drop a key TIDAL returned.
        base = {"top": {"id": "hit"}, "tracks": list(range(20)), "albums": list(range(20)),
                "artists": list(range(20)), "playlists": [9]}
        extra = {"tracks": ["n0", "n1", "n2", "n3"], "albums": ["a0"], "artists": ["r0"], "playlists": []}
        out = merge_search(base, extra)
        self.assertEqual(out["top"], {"id": "hit"})
        self.assertEqual(out["playlists"], [9])
        self.assertIn("n0", out["tracks"][:10])          # navidrome visible in the UI window
        self.assertIn(0, out["tracks"][:10])             # tidal still leads
        self.assertIn("a0", out["albums"][:8])
        self.assertIn("r0", out["artists"][:6])
        self.assertEqual(sorted(x for x in out["tracks"] if isinstance(x, int)), list(range(20)))
        self.assertEqual([x for x in out["tracks"] if isinstance(x, str)], ["n0", "n1", "n2", "n3"])
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

    async def test_tidal_error_surfaces_when_navidrome_has_nothing(self):
        # With no Navidrome results to show, a TIDAL failure must reach the
        # route (and so the UI), exactly as it did before this feature.
        class FailND:
            available = True
            async def search(self, q):
                raise NavidromeError("down")

        async def tidal_boom(q):
            raise RuntimeError("tidal session expired")

        with self.assertRaises(RuntimeError):
            await search_all(tidal_boom, FailND(), "x")

    async def test_tracks_for_navidrome(self):
        fake = FakeSubsonic()
        await fake.server.start_server()
        nd = Navidrome(str(fake.server.make_url("")), "u", "p")
        # a track with its dict attached plays as itself, no radio lookup
        tracks, ctx = await tracks_for_navidrome(nd, "track", "s1", {"id": "s1", "title": "Ferryman", "provider": "navidrome"})
        self.assertEqual([t["id"] for t in tracks], ["s1"])
        self.assertEqual(ctx["kind"], "track")
        # without the dict, getSong rebuilds it
        tracks, _ = await tracks_for_navidrome(nd, "track", "s1", None)
        self.assertEqual(tracks[0]["title"], "Ferryman")
        self.assertEqual(tracks[0]["provider"], "navidrome")
        # albums and artists hand back their items
        tracks, ctx = await tracks_for_navidrome(nd, "album", "al1", None)
        self.assertEqual([t["id"] for t in tracks], ["s1"])
        self.assertEqual(ctx["title"], "Across")
        tracks, ctx = await tracks_for_navidrome(nd, "artist", "a1", None)
        self.assertEqual([t["id"] for t in tracks], ["s1"])
        await nd.close()
        await fake.server.close()

    async def test_ping_single_flight_and_cache_invalidation(self):
        fake = FakeSubsonic()
        await fake.server.start_server()
        fake.delay = 0.3
        class Cfg:
            def __init__(self, d):
                self.d = d
            def text(self, k):
                return self.d.get(k, "")
        cfg = Cfg({"navidromeUrl": str(fake.server.make_url("")), "navidromeUser": "u", "navidromePass": "p"})
        nd = Navidrome.from_config(cfg)
        # two concurrent pings while the first is in flight: one request
        r = await asyncio.gather(nd.ping(), nd.ping())
        self.assertEqual(r, [True, True])
        self.assertEqual(len([1 for ep, _ in fake.calls if ep == "ping"]), 1)
        # changed credentials invalidate the cached answer
        fake.delay = 0
        cfg.d["navidromeUrl"] = "http://127.0.0.1:1"      # nothing listens there
        self.assertFalse(await nd.ping())
        # and a transport blow-up degrades to False, never an unhandled task error
        await nd.close()
        await fake.server.close()

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
