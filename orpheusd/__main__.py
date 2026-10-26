"""orpheusd: the Orpheus TIDAL player daemon.

Owns the TIDAL session and an mpv process, exposes MPRIS on the session bus,
and serves a small JSON API on 127.0.0.1 for the Orpheus shell UI.
"""

import argparse
import asyncio
import json
import logging
import os
import signal
from collections import OrderedDict
from pathlib import Path

from aiohttp import web

from .mpris import Mpris
from .player import Player
from . import eq as eqmod
from .lyrics import Lyrics
from .tidal import QUALITIES, Tidal
from .video import Video
from .youtube import YouTube, YouTubeError

log = logging.getLogger("orpheus")

HOME = Path.home()
STATE_DIR = Path(os.environ.get("XDG_STATE_HOME", HOME / ".local/state")) / "orpheus"
CACHE_DIR = Path(os.environ.get("XDG_CACHE_HOME", HOME / ".cache")) / "orpheus"
RUNTIME_DIR = Path(os.environ.get("XDG_RUNTIME_DIR", "/tmp")) / "orpheus"
PREFS = STATE_DIR / "daemon.json"
RESUME = STATE_DIR / "resume.json"
DEFAULT_PORT = 47837


class App:
    def __init__(self):
        for d in (STATE_DIR, CACHE_DIR, RUNTIME_DIR):
            d.mkdir(parents=True, exist_ok=True)
        self.prefs = self._load_prefs()
        self.tidal = Tidal(STATE_DIR, self.prefs.get("quality"))
        self.youtube = YouTube()
        self.player = Player(self.tidal, self.youtube, RUNTIME_DIR, CACHE_DIR, self._changed)
        self.video = Video(RUNTIME_DIR, self._changed)
        self.player.eq = eqmod.normalize(self.prefs.get("eq"))
        self.lyrics = Lyrics(self.tidal, CACHE_DIR)
        self.mpris = Mpris(self, self.player)

        self.version = 0
        self._cache: OrderedDict[str, dict] = OrderedDict()
        self._waiters: list[asyncio.Future] = []

    # ---- prefs ---------------------------------------------------------------

    def _load_prefs(self) -> dict:
        try:
            return json.loads(PREFS.read_text())
        except Exception:
            return {}

    def _save_prefs(self):
        # Quality is only stored once picked by hand; otherwise it stays on "best available".
        if self.tidal.preferred:
            self.prefs["quality"] = self.tidal.preferred
        else:
            self.prefs.pop("quality", None)
        self.prefs["volume"] = round(self.player.volume)
        self.prefs["eq"] = self.player.eq
        PREFS.write_text(json.dumps(self.prefs, indent=2) + "\n")

    # ---- change notification -------------------------------------------------

    def _changed(self):
        self.version += 1
        self.mpris.refresh()
        waiters, self._waiters = self._waiters, []
        for w in waiters:
            if not w.done():
                w.set_result(True)

    def raise_ui(self):
        asyncio.create_task(asyncio.create_subprocess_exec("omarchy-shell", "-q", "orpheus", "library"))

    # ---- lists (cached) ------------------------------------------------------

    async def fetch(self, kind: str, item_id: str) -> dict:
        key = f"{kind}:{item_id}"
        if key in self._cache:
            self._cache.move_to_end(key)
            return self._cache[key]
        fn = {"album": self.tidal.album, "playlist": self.tidal.playlist,
              "mix": self.tidal.mix, "artist": self.tidal.artist}.get(kind)
        if not fn:
            raise web.HTTPBadRequest(text=f"unknown kind {kind}")
        data = await fn(item_id)
        self._cache[key] = data
        while len(self._cache) > 40:
            self._cache.popitem(last=False)
        return data

    async def tracks_for(self, body: dict) -> tuple[list, dict]:
        kind, item_id = body.get("kind"), str(body.get("id", ""))
        if body.get("tracks"):
            return body["tracks"], body.get("context") or {}
        if kind == "track":
            radio = await self.tidal.radio(item_id)
            first = body.get("track")
            tracks = ([first] if first else []) + [t for t in radio if t["id"] != item_id]
            return tracks, {"kind": "radio", "id": item_id, "title": "Track radio"}
        data = await self.fetch(kind, item_id)
        return data.get("items", []), {"kind": kind, "id": item_id, "title": data.get("title", "")}

    # ---- lifecycle -------------------------------------------------------------

    async def start(self, port: int):
        await self.player.start()
        if "volume" in self.prefs:
            await self.player.set_volume(self.prefs["volume"])
        try:
            await self.mpris.start()
        except Exception as e:
            log.warning("MPRIS unavailable: %s", e)
        await self.tidal.restore()
        asyncio.create_task(self._liked_loop())
        if self.tidal.signed_in and RESUME.exists():
            try:
                await self.player.restore(json.loads(RESUME.read_text()))
            except Exception as e:
                log.warning("couldn't resume: %s", e)
        runner = web.AppRunner(self.routes())
        await runner.setup()
        await web.TCPSite(runner, "127.0.0.1", port).start()
        log.info("orpheusd listening on 127.0.0.1:%d (%s)", port, self.tidal.login_state["state"])
        return runner

    def status(self) -> dict:
        player = self.player.state()
        t = player.get("track")
        if t:
            player["track"] = dict(t, liked=self.tidal.is_liked("track", t["id"]),
                                   artistLiked=self.tidal.is_liked("artist", t.get("artistId", "")),
                                   albumLiked=self.tidal.is_liked("album", t.get("albumId", "")))
        return {"version": self.version, "login": self.tidal.login_state,
                "quality": self.tidal.quality, "player": player,
                "eq": self.player.eq_state(),
                "video": self.video.state(),
                "likedVersion": self.tidal.liked_version}

    async def _liked_loop(self):
        # Load likes once per sign-in (also after signing in later).
        while True:
            if self.tidal.signed_in and not self.tidal.liked_loaded:
                try:
                    await self.tidal.load_liked()
                    self._changed()
                except Exception as e:
                    log.warning("couldn't load likes: %s", e)
            await asyncio.sleep(3)

    # ---- HTTP API --------------------------------------------------------------

    def routes(self) -> web.Application:
        r = web.RouteTableDef()
        J = web.json_response

        async def body(req):
            try:
                return await req.json()
            except Exception:
                return {}

        def need_login():
            if not self.tidal.signed_in:
                raise web.HTTPUnauthorized(text="sign in to TIDAL first")

        @r.get("/status")
        async def status(req):
            # Long-poll: ?since=<version> waits up to 25 s for a change.
            since = req.query.get("since")
            if since is not None and int(since) == self.version:
                fut = asyncio.get_running_loop().create_future()
                self._waiters.append(fut)
                try:
                    await asyncio.wait_for(fut, 25)
                except asyncio.TimeoutError:
                    pass
            return J(self.status())

        @r.post("/login/link")
        async def login_link(req):
            return J(await self.tidal.start_link_login())

        @r.post("/login/pkce/start")
        async def login_pkce_start(req):
            return J(self.tidal.pkce_url())

        @r.post("/login/pkce/finish")
        async def login_pkce_finish(req):
            state = await self.tidal.finish_pkce((await body(req)).get("url", ""))
            self._changed()
            return J(state)

        @r.post("/logout")
        async def logout(req):
            await self.tidal.sign_out()
            self._changed()
            return J(self.tidal.login_state)

        @r.post("/quality")
        async def quality(req):
            q = (await body(req)).get("quality", "")
            if q not in QUALITIES:
                raise web.HTTPBadRequest(text=f"quality must be one of {', '.join(QUALITIES)}")
            self.tidal.set_quality(q)
            # Picking the best available quality again means "auto" (follows the sign-in).
            self.tidal.preferred = None if q == self.tidal.best_quality() else q
            self._save_prefs()
            self._changed()
            return J({"quality": q})

        @r.get("/search")
        async def search(req):
            need_login()
            q = req.query.get("q", "").strip()
            return J(await self.tidal.search(q) if q else {"tracks": [], "albums": [], "artists": [], "playlists": []})

        @r.get("/{kind:album|playlist|mix|artist}/{id}")
        async def item(req):
            need_login()
            return J(await self.fetch(req.match_info["kind"], req.match_info["id"]))

        @r.get("/collection/{what}")
        async def collection(req):
            need_login()
            return J(await self.tidal.collection(req.match_info["what"]))

        @r.get("/lyrics/{id}")
        async def lyrics(req):
            need_login()
            tid = req.match_info["id"]
            # LRCLIB matches on title/artist/album/duration, so hand it the
            # metadata we already hold rather than making it guess from an id.
            meta = {}
            for t in ([self.player.current] if self.player.current else []) + self.player.queue:
                if t and str(t.get("id")) == str(tid):
                    meta = t
                    break
            return J(await self.lyrics.get(tid, meta))

        @r.get("/eq")
        async def eq_get(req):
            # describe() carries the band centres and the preset list, so the UI
            # never has to hardcode the spec.
            return J({**eqmod.describe(), "state": self.player.eq_state()})

        @r.post("/eq")
        async def eq_set(req):
            b = await body(req)
            if "preset" in b and b["preset"]:
                preset = eqmod.preset_by_id(str(b["preset"]))
                if preset is None:
                    raise web.HTTPBadRequest(text=f"unknown preset: {b['preset']}")
                state = {
                    "enabled": bool(b.get("enabled", True)),
                    "gains": preset["gains"],
                    "preamp": preset.get("preamp"),
                    "preset": preset["id"],
                }
            else:
                state = dict(self.player.eq)
                if "gains" in b:
                    state["gains"] = b["gains"]
                    state["preset"] = None   # hand-edited, so it is no longer the preset
                if "band" in b:
                    # one band at a time, for a slider drag
                    try:
                        i = int(b["band"])
                    except (TypeError, ValueError):
                        raise web.HTTPBadRequest(text="band must be an index")
                    if not 0 <= i < len(eqmod.BANDS):
                        raise web.HTTPBadRequest(text=f"band must be 0..{len(eqmod.BANDS) - 1}")
                    gains = list(state["gains"])
                    gains[i] = b.get("gain", 0)
                    state["gains"] = gains
                    state["preset"] = None
                if "preamp" in b:
                    state["preamp"] = b["preamp"]
                if "enabled" in b:
                    state["enabled"] = bool(b["enabled"])
            out = await self.player.set_eq(state)
            self._save_prefs()
            return J(out)

        @r.post("/eq/presets")
        async def eq_import(req):
            # Import a correction from an AutoEq "FixedBandEQ.txt". The text is
            # posted by the client; Orpheus ships no measurement data of its own,
            # because AutoEq's MIT licence covers its code and not the
            # measurements behind it.
            b = await body(req)
            name = str(b.get("name", "")).strip()
            text = b.get("text", "")
            if not name:
                raise web.HTTPBadRequest(text="a name is required")
            try:
                parsed = eqmod.parse_fixed_band(text)
            except ValueError as e:
                raise web.HTTPBadRequest(text=str(e))
            entry = eqmod.save_device_preset(
                name, parsed["gains"], parsed["preamp"],
                source=str(b.get("source", "")), note=str(b.get("note", "")))
            return J({"preset": entry, "warnings": parsed["warnings"]})

        @r.delete("/eq/presets/{id}")
        async def eq_preset_delete(req):
            if not eqmod.delete_device_preset(req.match_info["id"]):
                raise web.HTTPNotFound(text="no such preset")
            return J({"ok": True})

        @r.post("/play")
        async def play(req):
            need_login()
            b = await body(req)
            tracks, ctx = await self.tracks_for(b)
            await self.player.play_list(tracks, int(b.get("index", 0)), ctx)
            return J(self.status())

        @r.post("/enqueue")
        async def enqueue(req):
            need_login()
            b = await body(req)
            if b.get("kind") == "track" and b.get("track"):
                tracks = [b["track"]]
            else:
                tracks, _ = await self.tracks_for(b)
            await self.player.enqueue(tracks, next_up=bool(b.get("next")))
            return J(self.status())

        @r.post("/control/{action}")
        async def control(req):
            a = req.match_info["action"]
            b = await body(req)
            p = self.player
            if a == "toggle":
                await p.toggle()
            elif a == "play":
                await p.set_paused(False)
            elif a == "pause":
                await p.set_paused(True)
            elif a == "next":
                await p.next()
            elif a == "previous":
                await p.previous()
            elif a == "seek":
                await p.seek(float(b.get("position", 0)))
            elif a == "volume":
                await p.set_volume(float(b.get("volume", 100)))
                self._save_prefs()
            elif a == "shuffle":
                await p.set_shuffle(bool(b.get("on", not p.shuffle)))
            elif a == "repeat":
                order = ["off", "all", "one"]
                await p.set_repeat(b.get("mode") or order[(order.index(p.repeat) + 1) % 3])
            elif a == "jump":
                await p.jump(int(b.get("index", 0)))
            elif a == "remove":
                await p.remove(int(b.get("index", -1)))
            else:
                raise web.HTTPNotFound(text=f"unknown action {a}")
            return J(self.status())

        @r.post("/favorite")
        async def favorite(req):
            """Body {kind, id, on?}; without `on` it toggles. Returns the new state."""
            need_login()
            b = await body(req)
            kind = b.get("kind")
            if kind not in ("track", "album", "artist", "playlist"):
                raise web.HTTPBadRequest(text="kind must be track|album|artist|playlist")
            on = b.get("on")
            liked = await self.tidal.favorite(kind, str(b.get("id")), None if on is None else bool(on))
            self._changed()
            return J({"kind": kind, "id": str(b.get("id")), "liked": liked})

        @r.get("/liked")
        async def liked(req):
            need_login()
            return J({"version": self.tidal.liked_version, **{k: sorted(v) for k, v in self.tidal.liked.items()}})

        # ---- youtube ---------------------------------------------------------

        @r.get("/yt/search")
        async def yt_search(req):
            """Search, or resolve a pasted link. Needs no TIDAL session."""
            try:
                results = await self.youtube.search(req.query.get("q", ""),
                                                    max(1, min(40, int(req.query.get("n", 20)))))
            except YouTubeError as e:
                raise web.HTTPBadGateway(text=str(e))
            return J({"query": req.query.get("q", ""), "results": results})

        @r.post("/yt/play")
        async def yt_play(req):
            """Body {items, index, mode}: `audio` goes through the music player
            with everything that implies - queue, equaliser, visualiser - and
            `video` opens the window."""
            b = await body(req)
            items = b.get("items") or ([b["item"]] if b.get("item") else [])
            if not items:
                raise web.HTTPBadRequest(text="items is required")
            index = max(0, min(len(items) - 1, int(b.get("index", 0))))
            if b.get("mode") == "video":
                # Never two things playing at once.
                await self.player.set_paused(True)
                await self.video.watch(items[index])
            else:
                await self.video.pause()
                await self.player.play_list(items, index,
                                            b.get("context") or {"kind": "youtube", "title": "youtube"})
            return J(self.status())

        @r.post("/video/{action}")
        async def video_control(req):
            a = req.match_info["action"]
            if not await self.video.command(a, await body(req)):
                if not self.video.running:
                    raise web.HTTPConflict(text="no video window open")
                raise web.HTTPNotFound(text=f"unknown action {a}")
            return J(self.status())

        app = web.Application()
        app.add_routes(r)
        return app


async def serve(port: int):
    app = App()
    runner = await app.start(port)
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, stop.set)
    await stop.wait()
    await app.video.close()
    try:
        RESUME.write_text(json.dumps(app.player.snapshot()))
    except Exception as e:
        log.warning("couldn't save resume state: %s", e)
    await app.player.stop()
    await runner.cleanup()


def main():
    ap = argparse.ArgumentParser(prog="orpheusd", description="Orpheus TIDAL player daemon")
    ap.add_argument("--port", type=int, default=int(os.environ.get("ORPHEUS_PORT", DEFAULT_PORT)))
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(levelname)s %(name)s: %(message)s")
    asyncio.run(serve(args.port))


if __name__ == "__main__":
    main()
