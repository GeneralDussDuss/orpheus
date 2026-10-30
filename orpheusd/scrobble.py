"""Scrobbling to ListenBrainz and Last.fm.

Both are off until their credentials exist in config.json:

  ListenBrainz  `listenbrainzToken`: the user token from
                https://listenbrainz.org/settings/
  Last.fm       `lastfmKey` and `lastfmSecret`: an API account from
                https://www.last.fm/api/account/create; then the settings
                page's "connect last.fm" runs the desktop auth flow
                (auth.getToken -> approve in the browser -> auth.getSession)
                and the session key is kept in STATE_DIR/lastfm.json.

Now-playing goes out when a track has played for a couple of seconds and is
not retried. A scrobble is queued in SQLite once the track is over and met
the rule (longer than 30 s; half of it, or 4 minutes, heard), then sent in
batches and retried with back-off, so offline listening is submitted later.
Only TIDAL tracks are scrobbled: YouTube titles are not song metadata.

`listenbrainzUrl` / `lastfmUrl` (or ORPHEUS_LISTENBRAINZ_URL /
ORPHEUS_LASTFM_URL) point the clients at another server, for tests.
"""

import asyncio
import hashlib
import json
import logging
import os
import time
from pathlib import Path

import aiohttp

from .system import write_atomic

log = logging.getLogger("orpheus.scrobble")

LB_URL = "https://api.listenbrainz.org"
LASTFM_URL = "https://ws.audioscrobbler.com/2.0/"
LASTFM_AUTH = "https://www.last.fm/api/auth/"
CLIENT = "Orpheus"


class Rejected(Exception):
    """The service refused the data itself: retrying will not help."""


class Scrobbler:
    def __init__(self, config, history, state_dir: Path):
        self.config = config
        self.history = history
        self.lastfm_file = state_dir / "lastfm.json"
        self._http: aiohttp.ClientSession | None = None
        self._kick = asyncio.Event()
        self._task = None
        self._lastfm_token = ""          # between auth start and finish
        self.last_error: dict[str, str] = {}
        self.sent: dict[str, int] = {"listenbrainz": 0, "lastfm": 0}
        self.lb_user = ""
        self._lb_checked_token = ""

    # ---- configuration -------------------------------------------------------

    @property
    def lb_token(self) -> str:
        return self.config.text("listenbrainzToken")

    @property
    def lb_url(self) -> str:
        return (os.environ.get("ORPHEUS_LISTENBRAINZ_URL") or self.config.text("listenbrainzUrl") or LB_URL).rstrip("/")

    @property
    def lastfm_url(self) -> str:
        return os.environ.get("ORPHEUS_LASTFM_URL") or self.config.text("lastfmUrl") or LASTFM_URL

    def lastfm_session(self) -> dict:
        try:
            return json.loads(self.lastfm_file.read_text(encoding="utf-8"))
        except Exception:
            return {}

    def enabled(self) -> list[str]:
        out = []
        if self.lb_token:
            out.append("listenbrainz")
        if self.config.text("lastfmKey") and self.config.text("lastfmSecret") and self.lastfm_session().get("key"):
            out.append("lastfm")
        return out

    def state(self) -> dict:
        pend = self.history.pending()
        lf = self.lastfm_session()
        return {
            "listenbrainz": {"enabled": bool(self.lb_token), "user": self.lb_user,
                             "pending": pend.get("listenbrainz", 0), "sent": self.sent["listenbrainz"],
                             "error": self.last_error.get("listenbrainz", "")},
            "lastfm": {"enabled": "lastfm" in self.enabled(),
                       "configured": bool(self.config.text("lastfmKey") and self.config.text("lastfmSecret")),
                       "user": lf.get("name", ""), "authorising": bool(self._lastfm_token),
                       "pending": pend.get("lastfm", 0), "sent": self.sent["lastfm"],
                       "error": self.last_error.get("lastfm", "")},
        }

    # ---- lifecycle ---------------------------------------------------------------

    def start(self):
        self._task = asyncio.create_task(self._loop())

    async def close(self):
        if self._task:
            self._task.cancel()
        if self._http and not self._http.closed:
            await self._http.close()

    def http(self) -> aiohttp.ClientSession:
        if self._http is None or self._http.closed:
            self._http = aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=15),
                                               headers={"User-Agent": f"{CLIENT}/0.1"})
        return self._http

    # ---- what the player calls -------------------------------------------------------

    @staticmethod
    def _eligible(track: dict) -> bool:
        return (track.get("provider") in (None, "", "tidal") and bool(track.get("title"))
                and bool(track.get("artists")))

    def now_playing(self, track: dict):
        if not self._eligible(track):
            return
        for svc in self.enabled():
            asyncio.create_task(self._now_playing(svc, track))

    def scrobble(self, track: dict, started: float):
        if not self._eligible(track):
            return
        slim = {k: track.get(k) for k in ("id", "title", "artists", "album", "duration", "isrc")}
        for svc in self.enabled():
            self.history.queue_scrobble(svc, int(started), slim)
        self._kick.set()

    async def _now_playing(self, svc: str, track: dict):
        try:
            if svc == "listenbrainz":
                await self._lb_submit("playing_now", [{"track_metadata": self._lb_meta(track)}])
            else:
                await self._lastfm_call("track.updateNowPlaying", self._lastfm_track(track), post=True)
        except Exception as e:
            log.debug("%s now-playing failed: %s", svc, e)

    # ---- the queue ---------------------------------------------------------------------

    async def _loop(self):
        while True:
            try:
                await asyncio.wait_for(self._kick.wait(), 60)
            except asyncio.TimeoutError:
                pass
            self._kick.clear()
            try:
                await self.flush()
            except Exception as e:
                log.warning("scrobble flush failed: %s", e)

    async def flush(self):
        for svc in self.enabled():
            while True:
                due = await asyncio.to_thread(self.history.due_scrobbles, svc, 50)
                if not due:
                    break
                ids = [d[0] for d in due]
                try:
                    if svc == "listenbrainz":
                        await self._lb_submit("single" if len(due) == 1 else "import",
                                              [{"listened_at": at, "track_metadata": self._lb_meta(t)}
                                               for _, at, t in due])
                    else:
                        params = {}
                        for i, (_, at, t) in enumerate(due):
                            for k, v in self._lastfm_track(t).items():
                                params[f"{k}[{i}]"] = v
                            params[f"timestamp[{i}]"] = str(at)
                        await self._lastfm_call("track.scrobble", params, post=True)
                except Rejected as e:
                    log.warning("%s rejected %d scrobble(s): %s", svc, len(ids), e)
                    self.last_error[svc] = str(e)
                    await asyncio.to_thread(self.history.scrobble_failed, ids, str(e), True)
                    continue
                except Exception as e:
                    log.info("%s unreachable, %d scrobble(s) stay queued: %s", svc, len(ids), e)
                    self.last_error[svc] = str(e) or type(e).__name__
                    await asyncio.to_thread(self.history.scrobble_failed, ids, str(e))
                    break
                self.last_error.pop(svc, None)
                self.sent[svc] += len(ids)
                await asyncio.to_thread(self.history.scrobbled, ids)

    # ---- ListenBrainz ----------------------------------------------------------------------

    @staticmethod
    def _lb_meta(t: dict) -> dict:
        info = {"submission_client": CLIENT, "media_player": CLIENT, "music_service": "tidal.com",
                "artist_names": list(t.get("artists") or [])}
        if t.get("duration"):
            info["duration_ms"] = int(float(t["duration"]) * 1000)
        if t.get("isrc"):
            info["isrc"] = t["isrc"]
        if t.get("id"):
            info["origin_url"] = f"https://tidal.com/browse/track/{t['id']}"
        meta = {"artist_name": ", ".join(t.get("artists") or []), "track_name": t.get("title") or "",
                "additional_info": info}
        if t.get("album"):
            meta["release_name"] = t["album"]
        return meta

    async def _lb_submit(self, listen_type: str, payload: list):
        token = self.lb_token
        if not token:
            raise RuntimeError("no ListenBrainz token")
        async with self.http().post(f"{self.lb_url}/1/submit-listens",
                                    json={"listen_type": listen_type, "payload": payload},
                                    headers={"Authorization": f"Token {token}"}) as r:
            text = await r.text()
            if r.status == 200:
                return
            if r.status == 400:
                raise Rejected(f"HTTP 400: {text[:200]}")
            raise RuntimeError(f"HTTP {r.status}: {text[:200]}")

    async def check_listenbrainz(self) -> dict:
        """Validate the token once per token, for the settings page."""
        token = self.lb_token
        if not token:
            self.lb_user = ""
            return {"valid": False}
        if token == self._lb_checked_token and self.lb_user:
            return {"valid": True, "user": self.lb_user}
        try:
            async with self.http().get(f"{self.lb_url}/1/validate-token",
                                       headers={"Authorization": f"Token {token}"}) as r:
                d = await r.json(content_type=None)
            self._lb_checked_token = token
            self.lb_user = d.get("user_name", "") if d.get("valid") else ""
            if not d.get("valid"):
                self.last_error["listenbrainz"] = "token not valid"
            return {"valid": bool(d.get("valid")), "user": self.lb_user}
        except Exception as e:
            return {"valid": None, "error": str(e)}

    # ---- Last.fm ------------------------------------------------------------------------------

    @staticmethod
    def _lastfm_track(t: dict) -> dict:
        p = {"artist": (t.get("artists") or [""])[0], "track": t.get("title") or ""}
        if t.get("album"):
            p["album"] = t["album"]
        if t.get("duration"):
            p["duration"] = str(int(float(t["duration"])))
        return p

    def _sign(self, params: dict) -> str:
        secret = self.config.text("lastfmSecret")
        raw = "".join(k + str(params[k]) for k in sorted(params) if k not in ("format", "callback"))
        return hashlib.md5((raw + secret).encode("utf-8")).hexdigest()

    async def _lastfm_call(self, method: str, params: dict, post: bool = False, session: bool = True) -> dict:
        key = self.config.text("lastfmKey")
        if not key or not self.config.text("lastfmSecret"):
            raise RuntimeError("no Last.fm API key/secret")
        p = dict(params, method=method, api_key=key)
        if session:
            sk = self.lastfm_session().get("key")
            if not sk:
                raise RuntimeError("Last.fm is not connected")
            p["sk"] = sk
        p["api_sig"] = self._sign(p)
        p["format"] = "json"
        http = self.http()
        req = http.post(self.lastfm_url, data=p) if post else http.get(self.lastfm_url, params=p)
        async with req as r:
            try:
                d = await r.json(content_type=None)
            except Exception:
                raise RuntimeError(f"HTTP {r.status}")
        if isinstance(d, dict) and d.get("error"):
            code, msg = d.get("error"), d.get("message", "")
            if code in (11, 16, 29, 8):          # unavailable, temporary, rate limit, backend
                raise RuntimeError(f"Last.fm {code}: {msg}")
            if code == 9:                        # session revoked: keep the scrobbles, ask to reconnect
                raise RuntimeError("Last.fm session is no longer valid; connect again")
            raise Rejected(f"Last.fm {code}: {msg}")
        if r.status != 200:
            raise RuntimeError(f"HTTP {r.status}")
        return d

    async def lastfm_auth_start(self) -> dict:
        """Step 1: a request token and the page where the user approves it."""
        d = await self._lastfm_call("auth.getToken", {}, session=False)
        self._lastfm_token = d.get("token", "")
        if not self._lastfm_token:
            raise RuntimeError("Last.fm gave no token")
        return {"url": f"{LASTFM_AUTH}?api_key={self.config.text('lastfmKey')}&token={self._lastfm_token}"}

    async def lastfm_auth_finish(self) -> dict:
        """Step 2, once approved: trade the token for a session key, which does not expire."""
        if not self._lastfm_token:
            raise RuntimeError("start the Last.fm sign-in first")
        d = await self._lastfm_call("auth.getSession", {"token": self._lastfm_token}, session=False)
        s = d.get("session") or {}
        if not s.get("key"):
            raise RuntimeError("Last.fm did not return a session")
        self._lastfm_token = ""
        write_atomic(self.lastfm_file, json.dumps({"name": s.get("name", ""), "key": s["key"],
                                                    "at": int(time.time())}).encode())
        self.last_error.pop("lastfm", None)
        return {"user": s.get("name", "")}

    def lastfm_disconnect(self):
        self.lastfm_file.unlink(missing_ok=True)
