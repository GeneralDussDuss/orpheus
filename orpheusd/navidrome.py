"""A self-hosted Navidrome server as a music source, over the Subsonic API.

Configured by three config.json keys, read at startup like the scrobbler's:

  navidromeUrl   e.g. "http://music.local:4533" (a trailing / or /rest is fine)
  navidromeUser
  navidromePass

With any of them missing nothing changes anywhere. With all three set the
daemon registers this class under Player.sources["navidrome"], merges its
search results into /search, serves its album and artist pages behind
`?provider=navidrome`, and scrobbles plays back to the server (which relays
to Last.fm/ListenBrainz if the user wired those up there). Every entry this
module emits carries `"provider": "navidrome"`, which is all the rest of
Orpheus needs: by the player it is just a URL.

Auth is Subsonic token auth: each request carries u, t = md5(password+salt),
a fresh salt s, v=1.16.1, c=Orpheus, f=json — the password itself never
goes on the wire.
"""

import asyncio
import hashlib
import logging
import secrets
import time
from urllib.parse import urlencode

import aiohttp

log = logging.getLogger("orpheus.navidrome")

VERSION = "1.16.1"
CLIENT = "Orpheus"
TIMEOUT = aiohttp.ClientTimeout(total=10)
PING_TTL = 30.0
LOSSLESS = ("flac", "alac", "wav", "aiff")


class NavidromeError(RuntimeError):
    pass


def _clean_url(url: str) -> str:
    url = (url or "").strip().rstrip("/")
    if url.endswith("/rest"):
        url = url[: -len("/rest")]
    return url


class Navidrome:
    def __init__(self, url: str, user: str, password: str):
        self._cfg = None
        self._url = _clean_url(url)
        self._user = (user or "").strip()
        self._password = password or ""
        self._session: aiohttp.ClientSession | None = None
        self._ping: tuple[tuple, float, bool] | None = None
        self._pinging: asyncio.Future | None = None

    @classmethod
    def from_config(cls, config) -> "Navidrome":
        """Read navidromeUrl/User/Pass from config on every use, so edits in
        the settings page apply without an orpheusd restart."""
        nd = cls("", "", "")
        nd._cfg = config
        return nd

    @property
    def url(self) -> str:
        return _clean_url(self._cfg.text("navidromeUrl")) if self._cfg else self._url

    @property
    def user(self) -> str:
        return (self._cfg.text("navidromeUser") if self._cfg else self._user).strip()

    @property
    def password(self) -> str:
        return self._cfg.text("navidromePass") if self._cfg else self._password

    @property
    def available(self) -> bool:
        return bool(self.url and self.user and self.password.strip())

    @property
    def host(self) -> str:
        from urllib.parse import urlparse
        return urlparse(self.url).netloc or self.url

    def last_ping(self) -> bool | None:
        """The most recent ping result without waiting for one; None = never."""
        return self._ping[2] if self._ping else None

    async def close(self):
        if self._session:
            await self._session.close()
            self._session = None

    # ---- plumbing -----------------------------------------------------------

    def _auth(self) -> dict:
        salt = secrets.token_hex(8)
        return {"u": self.user, "t": hashlib.md5((self.password + salt).encode()).hexdigest(),
                "s": salt, "v": VERSION, "c": CLIENT, "f": "json"}

    def rest_url(self, endpoint: str, **q) -> str:
        params = dict(self._auth(), **{k: v for k, v in q.items() if v is not None})
        return f"{self.url}/rest/{endpoint}?{urlencode(params)}"

    async def _get(self, endpoint: str, **q) -> dict:
        if self._session is None:
            self._session = aiohttp.ClientSession(timeout=TIMEOUT)
        params = dict(self._auth(), **{k: str(v) for k, v in q.items() if v is not None})
        try:
            async with self._session.get(f"{self.url}/rest/{endpoint}", params=params) as resp:
                data = await resp.json(content_type=None)
        except (aiohttp.ClientError, asyncio.TimeoutError, ValueError) as e:
            raise NavidromeError(f"navidrome unreachable: {e}") from e
        body = (data or {}).get("subsonic-response") or {}
        if body.get("status") != "ok":
            msg = ((body.get("error") or {}).get("message")) or "navidrome refused the request"
            raise NavidromeError(msg)
        return body

    # ---- entries ------------------------------------------------------------

    # The entries speak tidal.py's vocabulary exactly (track_dict/album_dict/
    # artist_dict): the UI, MPRIS, history and the player read those names.

    def _cover(self, art_id) -> str:
        return self.rest_url("getCoverArt", id=art_id, size=640) if art_id else ""

    @staticmethod
    def _quality(s: dict) -> str:
        suffix = (s.get("suffix") or "").lower()
        return "LOSSLESS" if suffix in LOSSLESS else (suffix.upper() if suffix else "")

    def _track(self, s: dict) -> dict:
        names = [a.get("name", "") for a in s.get("artists") or [] if a.get("name")] or \
                ([s.get("artist")] if s.get("artist") else [])
        return {"kind": "track", "provider": "navidrome", "id": str(s.get("id", "")),
                "title": s.get("title", ""), "artists": names,
                "artistId": str(s.get("artistId", "") or ""),
                "album": s.get("album", ""), "albumId": str(s.get("albumId", "") or ""),
                "duration": int(s.get("duration") or 0), "explicit": False,
                "quality": self._quality(s), "hires": False,
                "art": self._cover(s.get("coverArt")), "popularity": -1, "isrc": ""}

    def _album(self, a: dict) -> dict:
        return {"kind": "album", "provider": "navidrome", "id": str(a.get("id", "")),
                "title": a.get("name") or a.get("title", ""),
                "artists": [a.get("artist")] if a.get("artist") else [],
                "artistId": str(a.get("artistId", "") or ""),
                "tracks": int(a.get("songCount") or 0), "duration": int(a.get("duration") or 0),
                "year": str(a.get("year") or ""), "explicit": False,
                "art": self._cover(a.get("coverArt"))}

    def _artist(self, a: dict) -> dict:
        return {"kind": "artist", "provider": "navidrome", "id": str(a.get("id", "")),
                "title": a.get("name", ""), "art": self._cover(a.get("coverArt"))}

    # ---- the source surface (Player._resolve) --------------------------------

    async def stream(self, track_id: str) -> dict:
        body = await self._get("getSong", id=track_id)
        song = body.get("song") or {}
        suffix = (song.get("suffix") or "").lower()
        quality = "LOSSLESS" if suffix in LOSSLESS else (suffix.upper() if suffix else "")
        # Player._load reads info["source"]; "dash" False keeps the mpv path simple.
        return {"source": self.rest_url("stream", id=track_id, format="raw"), "dash": False,
                "quality": quality, "codec": suffix or None, "bitDepth": None, "sampleRate": None}

    def forget(self, track_id: str) -> None:
        pass                                   # stream URLs are deterministic

    # ---- browse --------------------------------------------------------------

    async def search(self, query: str) -> dict:
        body = await self._get("search3", query=query, songCount=20, albumCount=20, artistCount=20)
        res = body.get("searchResult3") or {}
        return {"top": None,
                "tracks": [self._track(s) for s in res.get("song", [])],
                "albums": [self._album(a) for a in res.get("album", [])],
                "artists": [self._artist(a) for a in res.get("artist", [])],
                "playlists": []}

    # The pages are flat, like tidal.py's album()/artist(): the entry dict
    # itself plus "items" (and "albums"/"singles" for artists).

    async def album(self, album_id: str) -> dict:
        body = await self._get("getAlbum", id=album_id)
        a = body.get("album") or {}
        d = self._album(a)
        d["items"] = [self._track(s) for s in a.get("song") or []]
        return d

    async def artist(self, artist_id: str) -> dict:
        body = await self._get("getArtist", id=artist_id)
        a = body.get("artist") or {}
        d = self._artist(a)
        d["albums"] = [self._album(al) for al in a.get("album") or []]
        d["singles"] = []
        d["items"] = []
        if d["title"]:
            try:
                top = await self._get("getTopSongs", artist=d["title"], count=10)
                d["items"] = [self._track(s) for s in (top.get("topSongs") or {}).get("song") or []]
            except NavidromeError:
                pass                       # a page without top songs still works
        return d

    # ---- health and scrobbling ------------------------------------------------

    async def ping(self) -> bool:
        key = (self.url, self.user, self.password)
        if self._ping and self._ping[0] == key and time.monotonic() - self._ping[1] < PING_TTL:
            return self._ping[2]
        if self._pinging is not None and not self._pinging.done():
            return await asyncio.shield(self._pinging)

        async def probe() -> bool:
            try:
                await self._get("ping")
                ok = True
            except Exception:                 # any failure means unreachable
                ok = False
            self._ping = (key, time.monotonic(), ok)
            return ok

        self._pinging = asyncio.ensure_future(probe())
        try:
            return await asyncio.shield(self._pinging)
        finally:
            if self._pinging.done():
                self._pinging = None

    async def scrobble(self, track_id: str, submission: bool) -> None:
        """Fire-and-forget: the server's play counts (and its own Last.fm /
        ListenBrainz relays) should never interrupt playback."""
        try:
            await self._get("scrobble", id=track_id, submission="true" if submission else "false")
        except NavidromeError as e:
            log.debug("scrobble: %s", e)


# ---- helpers the routes use --------------------------------------------------

# Library shows the first 10/8/6 of each list (plus the "top" hit), so a
# plain append would hide every Navidrome result behind TIDAL's twenty.
# Each list keeps TIDAL first but folds a few Navidrome entries into that
# visible window; nothing from either side is dropped.
_VISIBLE = {"tracks": (10, 3), "albums": (8, 3), "artists": (6, 2)}


def merge_search(base: dict, extra: dict) -> dict:
    """TIDAL's result with Navidrome's folded in; every base key survives."""
    out = dict(base)
    out.setdefault("top", None)
    out.setdefault("playlists", [])
    for k, (cap, reserve) in _VISIBLE.items():
        a, b = list(base.get(k) or []), list(extra.get(k) or [])
        keep = min(len(b), reserve) if a else 0
        head = a[: cap - keep] if keep else a[:cap]
        out[k] = head + b[:keep] + a[len(head):] + b[keep:]
    return out


async def search_all(tidal_search, navidrome, query: str) -> dict:
    """Both sides at once; either failing (or absent) contributes nothing.
    `tidal_search` is an async callable or None (signed out)."""
    empty = {"tracks": [], "albums": [], "artists": [], "playlists": []}

    async def side(coro_factory):
        if coro_factory is None:
            return empty, None
        try:
            return await coro_factory(query), None
        except Exception as e:
            log.warning("search: %s", e)
            return empty, e

    nd_search = navidrome.search if navidrome is not None and navidrome.available else None
    (tidal_out, tidal_err), (nd_out, nd_err) = await asyncio.gather(side(tidal_search), side(nd_search))
    # With nothing of Navidrome's to show, a TIDAL failure must still reach
    # the UI the way it always did (an expired session says "sign in", not
    # "no results").
    if tidal_err is not None and (nd_err is not None or nd_search is None):
        raise tidal_err
    return merge_search(tidal_out, nd_out)


async def tracks_for_navidrome(navidrome, kind: str, item_id: str, first_track) -> tuple[list, dict]:
    """What /play and /enqueue hand the player for a Navidrome item. A track
    plays as itself (no radio); albums and artists hand over their items."""
    if kind == "track":
        track = first_track
        if not track:
            info = await navidrome._get("getSong", id=item_id)
            track = navidrome._track(info.get("song") or {})
        return [track], {"kind": "track", "id": item_id, "title": track.get("title", "")}
    data = await getattr(navidrome, kind)(item_id)
    return data.get("items", []), {"kind": kind, "id": item_id, "title": data.get("title", "")}


def route_scrobble(navidrome, fallback, track: dict, *args, submission: bool) -> None:
    """Tracker callback shim: Navidrome-provided plays go to the server when
    it is available; everything else (including a navidrome track with the
    client torn down) takes the existing scrobbler path, whose own
    TIDAL-only filter applies untouched."""
    if (track or {}).get("provider") == "navidrome" and navidrome is not None and navidrome.available:
        try:
            asyncio.get_running_loop().create_task(
                navidrome.scrobble(str(track.get("id", "")), submission))
        except RuntimeError:
            pass                         # no loop (tests, shutdown): drop it
        return
    fallback(track, *args)
