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
import subprocess
import time
from collections import OrderedDict
from pathlib import Path

from aiohttp import web

from .anime import PLAYER as ANI_PLAYER, Anime, AnimeError
try:
    from .mpris import Mpris
except ImportError:  # no D-Bus on Windows
    Mpris = None
from .player import Player, QueueStore
from . import eq as eqmod
from . import endless
from .config import Config
from .history import History, Tracker
from .remote import Remote
from .scrobble import Scrobbler
from .lyrics import Lyrics
from .tidal import QUALITIES, Tidal
from .video import Video
from .soundcloud import SoundCloud
from .system import CACHE_DIR, RUNTIME_DIR, STATE_DIR, WINDOWS, curd_path
from .youtube import YouTube, YouTubeError

log = logging.getLogger("orpheus")

PREFS = STATE_DIR / "daemon.json"
DEFAULT_PORT = 47837


class NoMpris:
    """Stands in where there is no D-Bus. Windows media keys will come from SMTC."""

    async def start(self):
        pass

    def refresh(self):
        pass


class App:
    def __init__(self):
        for d in (STATE_DIR, CACHE_DIR, RUNTIME_DIR):
            d.mkdir(parents=True, exist_ok=True)
        self.prefs = self._load_prefs()
        # Always start on the best the sign-in allows. A quality picked through
        # /quality lasts until the daemon restarts; a saved one pinned users to
        # lossless long after they had signed in for hi-res.
        self.prefs.pop("quality", None)
        self.tidal = Tidal(STATE_DIR, None)
        self.youtube = YouTube()
        self.sources = {"youtube": self.youtube, "soundcloud": SoundCloud()}
        self.anime = Anime(RUNTIME_DIR)
        self.player = Player(self.tidal, self.sources, RUNTIME_DIR, CACHE_DIR, self._changed)
        self.store = QueueStore(STATE_DIR, self.player)
        self.video = Video(RUNTIME_DIR, self._changed)
        self.player.eq = eqmod.normalize(self.prefs.get("eq"))
        self.lyrics = Lyrics(self.tidal, CACHE_DIR)
        self.mpris = Mpris(self, self.player) if Mpris else NoMpris()

        # ---- listening: endless play, history, scrobbling, remote, sleep ----
        self.config = Config()
        self.history = History(STATE_DIR)
        self.scrobbler = Scrobbler(self.config, self.history, STATE_DIR)
        self.tracker = Tracker(self.history, self.scrobbler.now_playing, self.scrobbler.scrobble)
        self.remote = Remote(self, self.config)
        self.sleep: dict | None = None
        self._sleep_task = None
        self._endless_busy = False
        self._endless_last: dict = {}

        self.version = 0
        self.stop = asyncio.Event()     # set by POST /quit (or a signal): shut down cleanly
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
        self.store.poke()
        waiters, self._waiters = self._waiters, []
        for w in waiters:
            if not w.done():
                w.set_result(True)

    async def wait_change(self, since: int, timeout: float = 25):
        """Wait until the state moves past `since`, or `timeout` passes."""
        if since != self.version or self.stop.is_set():
            return
        fut = asyncio.get_running_loop().create_future()
        self._waiters.append(fut)
        try:
            await asyncio.wait_for(fut, timeout)
        except asyncio.TimeoutError:
            pass

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
        # The saved queue goes back before the port opens, so the first /status
        # already has it. It is only data: the stream resolves on play.
        try:
            snap = self.store.load()
            if snap and await self.player.restore(snap):
                self.store.mark_saved()
                log.info("restored a %d-track queue at %d, %.0f s in, paused",
                         len(self.player.queue), self.player.pos, self.player.position)
        except Exception as e:
            log.warning("couldn't restore the queue: %s", e)
        try:
            await self.mpris.start()
        except Exception as e:
            log.warning("MPRIS unavailable: %s", e)
        await self.tidal.restore()
        if getattr(self.tidal, "restore_pending", False):
            asyncio.create_task(self._restore_loop())
        asyncio.create_task(self._liked_loop())
        try:
            for d in await asyncio.to_thread(self.history.close_dangling):
                self.scrobbler.scrobble(d["track"], d["started"])
        except Exception as e:
            log.warning("history: %s", e)
        self.scrobbler.start()
        asyncio.create_task(self._listen_loop())
        asyncio.create_task(self.remote.loop())
        # No access log: the UIs long-poll /status, and a line per request
        # buried everything worth reading in orpheusd.log.
        runner = web.AppRunner(self.routes(), access_log=None)
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
                "providers": {"youtube": True, "soundcloud": True, "anime": self.anime.available,
                              "curd": self.anime.curd},
                "likedVersion": self.tidal.liked_version,
                "listening": {"endless": self.config.endless, "crossfade": self.config.crossfade,
                              "sleep": self.sleep_state(),
                              "scrobbling": self.scrobbler.enabled(),
                              "remote": self.remote.state()}}

    # ---- listening: the loop behind endless play, history and the sleep timer ----

    async def _listen_loop(self):
        while True:
            await asyncio.sleep(0.5)
            p = self.player
            try:
                p.crossfade = self.config.crossfade
                self.tracker.tick(p, end_slack=p.crossfade)
                await self._endless_check()
            except Exception as e:
                log.warning("listening loop: %s", e)

    async def _endless_check(self):
        """When the queue is about to run out (its last track has under 45 s to
        go) or has run out, append TIDAL radio for that last track."""
        p = self.player
        cur = p.current
        if (not self.config.endless or self._endless_busy or p.repeat != "off" or cur is None
                or p.pos != len(p.order) - 1 or not self.tidal.signed_in
                or cur.get("provider") not in (None, "", "tidal")):
            return
        remaining = (p.duration or cur.get("duration") or 0) - p.position
        if not (p.ended or (p.playing and remaining <= 45)):
            return
        key = (cur.get("id"), len(p.order))
        if self._endless_last.get("key") == key and time.monotonic() - self._endless_last.get("at", 0) < 60:
            return   # tried for this one a moment ago
        self._endless_last = {"key": key, "at": time.monotonic()}
        self._endless_busy = True
        try:
            seed, radio = await self.tidal.radio_from(str(cur["id"]))
            recent = await asyncio.to_thread(self.history.recent_ids)
            recent.discard(str(cur["id"]))
            seed = dict(cur, **{k: seed[k] for k in ("bpm", "popularity") if seed.get(k) not in (None, 0, -1)})
            picked = endless.pick(seed, radio, recent, p.queue, 20)
            if not picked:
                log.info("endless: no radio for %s", cur.get("id"))
                return
            marker = {"from": cur.get("title", ""), "fromId": str(cur.get("id")),
                      "artists": list(cur.get("artists") or [])}
            # still the same last track? the user may have moved on meanwhile
            if p.current is not cur or p.pos != len(p.order) - 1:
                return
            ended = p.ended
            await p.enqueue([dict(t, radio=marker) for t in picked])
            log.info("endless: %d radio tracks from %s (bpm %s)", len(picked), cur.get("id"),
                     [t.get("bpm") for t in picked])
            if ended:
                await p.jump(p.pos + 1)
        except Exception as e:
            log.warning("endless: couldn't get radio for %s: %s", cur.get("id"), e)
        finally:
            self._endless_busy = False

    # ---- the sleep timer ----------------------------------------------------------------

    SLEEP_FADE = 60.0

    def _sleep_remaining(self) -> float:
        s, p = self.sleep, self.player
        if s["endOfTrack"]:
            if not p.stop_after:
                return 0.0   # the player stopped at the end (or the stop was cleared)
            # Done only when the player says so: an interpolated position can
            # reach the duration a moment before mpv's end of file does.
            return max(0.05, (p.duration or 0) - p.position)
        return s["deadline"] - time.monotonic()

    def sleep_state(self):
        if not self.sleep:
            return {"active": False}
        s = self.sleep
        return {"active": True, "endOfTrack": s["endOfTrack"], "at": s.get("at"),
                "remaining": round(self._sleep_remaining()), "fading": s.get("fading", False)}

    async def set_sleep(self, minutes: float | None = None, end_of_track: bool = False):
        await self.cancel_sleep(notify=False)
        if end_of_track:
            p = self.player
            left = max(1.0, (p.duration or 0) - p.position)
            self.sleep = {"endOfTrack": True, "at": None, "total": left}
            await p.set_stop_after(True)
        elif minutes and minutes > 0:
            secs = float(minutes) * 60
            self.sleep = {"endOfTrack": False, "deadline": time.monotonic() + secs,
                          "at": round(time.time() + secs), "total": secs}
        if self.sleep:
            self._sleep_task = asyncio.create_task(self._sleep_run(self.sleep))
            log.info("sleep timer: %s", "end of track" if end_of_track else f"{minutes} min")
        self._changed()

    async def cancel_sleep(self, notify: bool = True):
        task, self._sleep_task = self._sleep_task, None
        self.sleep = None
        if task and task is not asyncio.current_task():
            task.cancel()
        self.player.suppress_xfade = False
        if self.player.stop_after:
            await self.player.set_stop_after(False)
        await self.player.set_gain(1.0)
        if notify:
            self._changed()

    async def _sleep_run(self, s: dict):
        """Count down; over the last minute fade out evenly in loudness (dB
        linear, to -60 dB), then pause and put the volume back."""
        p = self.player
        while self.sleep is s:
            rem = self._sleep_remaining()
            fade = min(self.SLEEP_FADE, s.get("total", self.SLEEP_FADE))
            # The fade owns the volume near the end: no crossfade into silence.
            p.suppress_xfade = rem < self.SLEEP_FADE + 30 + p.crossfade
            if rem <= 0:
                await p.set_gain(0.0)
                if not s["endOfTrack"]:
                    await p.set_paused(True)   # end of track: the player already stopped itself
                log.info("sleep timer: paused")
                await self.cancel_sleep()
                return
            if rem <= fade:
                if not s.get("fading"):
                    s["fading"] = True
                    self._changed()
                if p.playing:
                    await p.set_gain(10 ** (-3 * (1 - rem / fade)))
            await asyncio.sleep(0.1 if rem <= fade + 1 else 0.5)

    # ---- transport, shared by the API and the phone remote ----------------------------

    async def control(self, a: str, b: dict):
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

    async def _restore_loop(self):
        """The saved session could not be checked (no network at start): try
        again, 5 s apart rising to a minute, until it works or someone signs in."""
        wait = 5
        while self.tidal.restore_pending and not self.tidal.signed_in:
            await asyncio.sleep(wait)
            if self.tidal.signed_in:
                break
            if await self.tidal.restore():
                log.info("TIDAL session restored")
            wait = min(60, wait * 2)
            self._changed()

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
            if since is not None:
                await self.wait_change(int(since), 25)
            return J(self.status())

        @r.post("/quit")
        async def quit_(req):
            # The desktop app's Quit: stop the way a signal would, so the queue
            # and the last play are saved. Windows has no SIGTERM to send.
            log.info("quit requested")
            asyncio.get_running_loop().call_later(0.05, self.stop.set)
            return J({"ok": True})

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
            await self.control(req.match_info["action"], await body(req))
            return J(self.status())

        # ---- listening -------------------------------------------------------

        @r.get("/stats")
        async def stats(req):
            """?range=week|month|year|all|wrapped (wrapped: this calendar month,
            with the extra wrapped block)."""
            rng = req.query.get("range", "week")
            if rng not in ("week", "month", "year", "all", "wrapped"):
                raise web.HTTPBadRequest(text="range must be week|month|year|all|wrapped")
            try:
                top = max(1, min(50, int(req.query.get("top", 10))))
            except ValueError:
                top = 10
            return J(await asyncio.to_thread(self.history.stats, rng, None, top))

        @r.post("/sleep")
        async def sleep(req):
            """Body {minutes} | {endOfTrack: true} | {cancel: true} (or minutes 0)."""
            b = await body(req)
            if b.get("cancel") or (not b.get("endOfTrack") and not b.get("minutes")):
                await self.cancel_sleep()
            else:
                try:
                    minutes = float(b.get("minutes") or 0)
                except (TypeError, ValueError):
                    raise web.HTTPBadRequest(text="minutes must be a number")
                if not b.get("endOfTrack") and not 0 < minutes <= 24 * 60:
                    raise web.HTTPBadRequest(text="minutes must be 1..1440")
                await self.set_sleep(minutes, bool(b.get("endOfTrack")))
            return J(self.sleep_state())

        @r.get("/scrobble")
        async def scrobble_state(req):
            await self.scrobbler.check_listenbrainz()
            return J(self.scrobbler.state())

        @r.post("/scrobble/flush")
        async def scrobble_flush(req):
            await self.scrobbler.flush()
            return J(self.scrobbler.state())

        @r.post("/lastfm/auth/start")
        async def lastfm_start(req):
            try:
                return J(await self.scrobbler.lastfm_auth_start())
            except Exception as e:
                raise web.HTTPBadGateway(text=str(e))

        @r.post("/lastfm/auth/finish")
        async def lastfm_finish(req):
            try:
                out = await self.scrobbler.lastfm_auth_finish()
            except Exception as e:
                raise web.HTTPBadGateway(text=str(e))
            self._changed()
            return J(out)

        @r.post("/lastfm/disconnect")
        async def lastfm_disconnect(req):
            self.scrobbler.lastfm_disconnect()
            self._changed()
            return J(self.scrobbler.state())

        # Pairing for the phone remote: loopback only (never on the LAN listener).
        @r.get("/remote/pair")
        async def remote_pair(req):
            await self.remote.sync()
            return J(self.remote.pairing())

        @r.post("/remote/pair/reset")
        async def remote_reset(req):
            self.remote.reset_token()
            self._changed()
            return J(self.remote.pairing())

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
            """Search, or resolve a pasted link. Needs no TIDAL session.
            `?provider=soundcloud` asks SoundCloud instead; the route kept its
            name because every yt-dlp source answers through it."""
            source = self.sources.get(req.query.get("provider") or "youtube")
            if not source:
                raise web.HTTPNotFound(text="unknown provider")
            try:
                results = await source.search(req.query.get("q", ""),
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
                try:
                    await self.video.watch(items[index])
                except YouTubeError as e:
                    raise web.HTTPBadGateway(text=str(e))
            else:
                await self.video.pause()
                await self.player.play_list(items, index,
                                            b.get("context") or {"kind": "youtube", "title": "youtube"})
            return J(self.status())

        # ---- anime -----------------------------------------------------------
        #
        # A series is addressed by the search that found it plus its place in
        # the results, because that is all ani-cli's -S takes.

        @r.get("/anime/search")
        async def anime_search(req):
            try:
                results = await self.anime.search(req.query.get("q", ""))
            except AnimeError as e:
                raise web.HTTPBadGateway(text=str(e))
            return J({"query": req.query.get("q", ""), "results": results})

        @r.get("/anime/episodes")
        async def anime_episodes(req):
            try:
                results = await self.anime.episodes(req.query.get("q", ""),
                                                    int(req.query.get("i", 1)))
            except (AnimeError, ValueError) as e:
                raise web.HTTPBadGateway(text=str(e))
            return J({"results": results})

        @r.post("/anime/watch")
        async def anime_watch(req):
            """Body {query, index, ep, title}: resolve one episode and show it."""
            b = await body(req)
            query, ep = b.get("query") or "", str(b.get("ep") or "")
            if not query or not ep:
                raise web.HTTPBadRequest(text="query and ep are required")
            index = int(b.get("index") or 1)
            try:
                got = await self.anime.resolve(query, index, ep, b.get("quality") or "best")
            except AnimeError as e:
                raise web.HTTPBadGateway(text=str(e))
            # Never two things playing at once.
            await self.player.set_paused(True)
            title = got.get("title") or b.get("title") or f"{query} episode {ep}"
            entry = {"kind": "video", "provider": "anime", "id": f"{index}@{query}#{ep}",
                     "title": title, "query": query, "index": index, "ep": ep,
                     "duration": 0}
            await self.video.play(got["url"], entry, {
                "referrer": got.get("referrer"),
                "sub-files": got.get("subs"),
                "force-media-title": title,
            })
            return J(self.status())

        @r.post("/anime/curd")
        async def anime_curd(req):
            """Hand over to Curd, which owns its own player.

            Curd does AniList progress, intro skipping and Discord presence from
            inside mpv's IPC socket, so it has to be the one running it. Orpheus
            opens it in a terminal and stays out of the way.
            """
            if not self.anime.curd:
                raise web.HTTPNotFound(text="curd is not installed")
            args = ["-c"] if (await body(req)).get("resume") else []
            curd = curd_path()
            if WINDOWS:
                # Its own console; Curd plays through the mpv its installer bundles.
                cmd, how = [curd, *args], {"creationflags": subprocess.CREATE_NEW_CONSOLE}
            else:
                run = [curd, "-player", str(ANI_PLAYER), *args]
                term = os.environ.get("TERMINAL") or ""
                if not term or os.path.basename(term) == "xdg-terminal-exec":
                    # Omarchy's TERMINAL: the desktop's default terminal, which takes
                    # --title= and the command after --, not a terminal's own -e.
                    cmd = ["xdg-terminal-exec", "--title=Orpheus ╱╱ curd", "--", *run]
                else:
                    cmd = [term, "--title", "Orpheus ╱╱ curd", "-e", *run]
                how = {"stdin": asyncio.subprocess.DEVNULL}
            try:
                proc = await asyncio.create_subprocess_exec(*cmd, **how)
            except OSError as e:
                raise web.HTTPBadGateway(text=f"could not start curd: {e}")
            # A launcher that rejects its arguments exits at once; say so instead
            # of reporting a hand-over that never happened.
            try:
                code = await asyncio.wait_for(proc.wait(), 1.0)
            except asyncio.TimeoutError:
                code = None
            if code:
                log.warning("curd launcher %s exited %s", cmd[0], code)
                raise web.HTTPBadGateway(text=f"curd's terminal would not open ({cmd[0]} exited {code})")
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
        self.remote.add_routes(app)   # /remote and /remote/api, token-gated
        return app


async def serve(port: int):
    app = App()
    runner = await app.start(port)
    loop = asyncio.get_running_loop()
    if WINDOWS:
        # No add_signal_handler on Windows: Ctrl+C makes asyncio.run cancel this
        # task, POST /quit sets app.stop, and the finally saves the queue either way.
        try:
            await app.stop.wait()
        finally:
            await shutdown(app, runner)
            log.info("stopped")
        return
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, app.stop.set)
    await app.stop.wait()
    await shutdown(app, runner)


async def shutdown(app, runner):
    # Answer the long polls now: runner.cleanup() would otherwise wait out
    # their 25 s before the process could end.
    app.stop.set()
    waiters, app._waiters = app._waiters, []
    for w in waiters:
        if not w.done():
            w.set_result(True)
    await app.video.close()
    try:
        app.tracker.finish(app.player.crossfade)
    except Exception as e:
        log.warning("couldn't close the last play: %s", e)
    await app.remote.stop()
    await app.scrobbler.close()
    try:
        app.store.save_now()
    except Exception as e:
        log.warning("couldn't save the queue: %s", e)
    await app.player.stop()
    await runner.cleanup()


def main():
    ap = argparse.ArgumentParser(prog="orpheusd", description="Orpheus TIDAL player daemon")
    ap.add_argument("--port", type=int, default=int(os.environ.get("ORPHEUS_PORT", DEFAULT_PORT)))
    ap.add_argument("-v", "--verbose", action="store_true")
    ap.add_argument("--log", metavar="FILE", help="log to FILE, rotated at 1 MB (3 kept), not stderr")
    args = ap.parse_args()
    level = logging.DEBUG if args.verbose else logging.INFO
    if args.log:
        from logging.handlers import RotatingFileHandler
        Path(args.log).parent.mkdir(parents=True, exist_ok=True)
        handler = RotatingFileHandler(args.log, maxBytes=1 << 20, backupCount=3, encoding="utf-8")
        handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(name)s: %(message)s",
                                               "%m-%d %H:%M:%S"))
        logging.basicConfig(level=level, handlers=[handler])
    else:
        logging.basicConfig(level=level, format="%(levelname)s %(name)s: %(message)s")
    try:
        asyncio.run(serve(args.port))
    except KeyboardInterrupt:
        pass
    except BaseException:
        log.exception("orpheusd died")   # with --log, stderr may lead nowhere
        raise


if __name__ == "__main__":
    main()
