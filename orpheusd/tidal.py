"""TIDAL access for Orpheus: sign-in, browsing, and stream resolution.

tidalapi is synchronous, so every public coroutine here hops to a worker
thread. Everything handed to the rest of Orpheus is a plain JSON-able dict.
"""

import asyncio
import json
import logging
from pathlib import Path

import tidalapi
from tidalapi.media import Quality

log = logging.getLogger("orpheus.tidal")

QUALITIES = {
    "low": Quality.low_96k,
    "high": Quality.low_320k,
    "lossless": Quality.high_lossless,
    "hires": Quality.hi_res_lossless,
}


def _img(obj, size=320):
    try:
        return obj.image(size)
    except Exception:
        return ""


def _artists(obj):
    names = [a.name for a in (getattr(obj, "artists", None) or []) if a and a.name]
    if not names and getattr(obj, "artist", None):
        names = [obj.artist.name]
    return names


def track_dict(t):
    album = getattr(t, "album", None)
    return {
        "kind": "track",
        "id": str(t.id),
        "title": t.full_name if getattr(t, "full_name", None) else t.name,
        "artists": _artists(t),
        "artistId": str(t.artist.id) if getattr(t, "artist", None) else "",
        "album": album.name if album else "",
        "albumId": str(album.id) if album else "",
        "duration": int(getattr(t, "duration", 0) or 0),
        "explicit": bool(getattr(t, "explicit", False)),
        "quality": str(getattr(t, "audio_quality", "") or ""),
        "hires": bool(getattr(t, "is_hi_res_lossless", False)),
        "art": _img(album, 640) if album else "",
        "available": bool(getattr(t, "available", True)),
        # for endless play's ordering and for scrobbles; 0 / -1 / "" when TIDAL has none
        "bpm": int(getattr(t, "bpm", 0) or 0),
        "popularity": int(getattr(t, "popularity", -1) if getattr(t, "popularity", None) is not None else -1),
        "isrc": str(getattr(t, "isrc", "") or ""),
    }


def album_dict(a):
    year = ""
    rd = getattr(a, "release_date", None) or getattr(a, "tidal_release_date", None)
    if rd:
        year = str(rd.year)
    return {
        "kind": "album",
        "id": str(a.id),
        "title": a.name,
        "artists": _artists(a),
        "artistId": str(a.artist.id) if getattr(a, "artist", None) else "",
        "tracks": int(getattr(a, "num_tracks", 0) or 0),
        "duration": int(getattr(a, "duration", 0) or 0),
        "year": year,
        "explicit": bool(getattr(a, "explicit", False)),
        "art": _img(a, 640),
    }


def artist_dict(a):
    return {"kind": "artist", "id": str(a.id), "title": a.name, "art": _img(a, 480)}


def playlist_dict(p):
    creator = getattr(p, "creator", None)
    return {
        "kind": "playlist",
        "id": str(p.id),
        "title": p.name,
        "subtitle": (getattr(creator, "name", "") or "") if creator else "",
        "tracks": int(getattr(p, "num_tracks", 0) or 0),
        "duration": int(getattr(p, "duration", 0) or 0),
        "art": _img(p, 640),
    }


def mix_dict(m):
    return {
        "kind": "mix",
        "id": str(m.id),
        "title": m.title,
        "subtitle": getattr(m, "sub_title", "") or "",
        "art": _img(m, 640),
    }


def any_dict(obj):
    if isinstance(obj, tidalapi.media.Track):
        return track_dict(obj)
    if isinstance(obj, tidalapi.album.Album):
        return album_dict(obj)
    if isinstance(obj, tidalapi.artist.Artist):
        return artist_dict(obj)
    if isinstance(obj, tidalapi.playlist.Playlist):
        return playlist_dict(obj)
    if isinstance(obj, (tidalapi.mix.Mix, tidalapi.mix.MixV2)):
        return mix_dict(obj)
    return None


def _tracks_only(items):
    return [track_dict(t) for t in items if isinstance(t, tidalapi.media.Track)]


class Tidal:
    def __init__(self, state_dir: Path, quality: str | None = None):
        self.session_file = state_dir / "tidal-session.json"
        # None means "auto": the best the current sign-in allows (applied after sign-in).
        self.preferred = quality if quality in QUALITIES else None
        self.session = tidalapi.Session(tidalapi.Config(quality=QUALITIES.get(quality or "lossless")))
        self.login_state = {"state": "signed-out"}
        self._link_task = None
        # What the user has liked, by kind, for filled/empty hearts.
        self.liked: dict[str, set[str]] = {"track": set(), "album": set(), "artist": set(), "playlist": set()}
        self.liked_loaded = False
        self.liked_version = 0

    # ---- session ---------------------------------------------------------

    @property
    def signed_in(self) -> bool:
        return self.login_state.get("state") == "signed-in"

    async def restore(self) -> bool:
        def work():
            if not self.session_file.exists():
                return False
            ok = self.session.load_session_from_file(self.session_file)
            if ok and self.session.check_login():
                if self.session.is_pkce:
                    self.session.client_enable_hires()
                self.session.save_session_to_file(self.session_file)  # keep refreshed tokens
                return True
            return False

        try:
            ok = await asyncio.to_thread(work)
        except Exception as e:
            log.warning("could not restore TIDAL session: %s", e)
            ok = False
        if ok:
            self._set_signed_in()
        return ok

    def _set_signed_in(self):
        if self.session.is_pkce and self.preferred is None:
            self.session.audio_quality = QUALITIES["hires"]
        elif self.preferred:
            self.session.audio_quality = QUALITIES[self.preferred]
        else:
            self.session.audio_quality = QUALITIES[self.best_quality()]
        user = self.session.user
        name = getattr(user, "first_name", None) or getattr(user, "username", None) or ""
        self.login_state = {
            "state": "signed-in",
            "user": name,
            "hires": bool(self.session.is_pkce),
            "country": self.session.country_code,
        }

    async def start_link_login(self) -> dict:
        """Device-link sign-in: open a URL, approve, done. Lossless (16/44.1) max."""
        link, future = await asyncio.to_thread(self.session.login_oauth)
        url = link.verification_uri_complete
        if not url.startswith("http"):
            url = "https://" + url
        self.login_state = {"state": "waiting", "method": "link", "url": url,
                            "code": link.user_code, "expires": int(link.expires_in)}

        async def wait():
            try:
                ok = await asyncio.wrap_future(future)
                if ok and self.session.check_login():
                    await asyncio.to_thread(self.session.save_session_to_file, self.session_file)
                    self._set_signed_in()
                    return
            except Exception as e:
                log.warning("link login failed: %s", e)
            self.login_state = {"state": "signed-out", "error": "Sign-in expired or was declined"}

        self._link_task = asyncio.create_task(wait())
        return self.login_state

    def pkce_url(self) -> dict:
        """Hi-res sign-in, step 1: the browser login URL."""
        self.login_state = {"state": "waiting", "method": "pkce", "url": self.session.pkce_login_url()}
        return self.login_state

    async def finish_pkce(self, redirect_url: str) -> dict:
        """Hi-res sign-in, step 2: the URL of the 'Oops' page TIDAL redirected to."""
        def work():
            token = self.session.pkce_get_auth_token(redirect_url.strip())
            self.session.process_auth_token(token, is_pkce_token=True)
            self.session.client_enable_hires()
            self.session.save_session_to_file(self.session_file)

        try:
            await asyncio.to_thread(work)
            self._set_signed_in()
        except Exception as e:
            log.warning("pkce login failed: %s", e)
            self.login_state = {"state": "signed-out",
                                "error": "That URL didn't work. Copy the whole address of the 'Oops' page and try again."}
        return self.login_state

    async def sign_out(self):
        self.session_file.unlink(missing_ok=True)
        self.liked = {k: set() for k in self.liked}
        self.liked_loaded = False
        self.session = tidalapi.Session(tidalapi.Config(quality=self.session.config.quality))
        self.login_state = {"state": "signed-out"}

    def best_quality(self) -> str:
        """Highest quality this sign-in can stream: hi-res needs the PKCE (hi-res) sign-in."""
        return "hires" if self.session.is_pkce else "lossless"

    def set_quality(self, name: str) -> str:
        q = QUALITIES.get(name)
        if q is None:
            raise ValueError(f"unknown quality {name!r} ({'|'.join(QUALITIES)})")
        self.session.audio_quality = q
        return name

    @property
    def quality(self) -> str:
        current = str(self.session.audio_quality)
        return next((k for k, v in QUALITIES.items() if str(v) == current), "lossless")

    # ---- browsing ----------------------------------------------------------

    async def search(self, query: str, limit: int = 20) -> dict:
        def work():
            r = self.session.search(query, limit=limit)
            top = r.get("top_hit")
            return {
                "top": any_dict(top) if top else None,
                "tracks": [track_dict(t) for t in r.get("tracks", [])],
                "albums": [album_dict(a) for a in r.get("albums", [])],
                "artists": [artist_dict(a) for a in r.get("artists", [])],
                "playlists": [playlist_dict(p) for p in r.get("playlists", [])],
            }
        return await asyncio.to_thread(work)

    async def album(self, album_id: str) -> dict:
        def work():
            a = self.session.album(album_id)
            d = album_dict(a)
            d["items"] = [track_dict(t) for t in a.tracks()]
            return d
        return await asyncio.to_thread(work)

    async def playlist(self, playlist_id: str) -> dict:
        def work():
            p = self.session.playlist(playlist_id)
            d = playlist_dict(p)
            d["items"] = _tracks_only(p.tracks(limit=1000))
            return d
        return await asyncio.to_thread(work)

    async def mix(self, mix_id: str) -> dict:
        def work():
            m = self.session.mix(mix_id)
            d = mix_dict(m)
            d["items"] = _tracks_only(m.items())
            return d
        return await asyncio.to_thread(work)

    async def artist(self, artist_id: str) -> dict:
        def work():
            a = self.session.artist(artist_id)
            d = artist_dict(a)
            d["items"] = [track_dict(t) for t in a.get_top_tracks(limit=20)]
            d["albums"] = [album_dict(x) for x in a.get_albums(limit=50)]
            try:
                d["singles"] = [album_dict(x) for x in a.get_albums_ep_singles(limit=50)]
            except Exception:
                d["singles"] = []
            return d
        return await asyncio.to_thread(work)

    async def collection(self, what: str) -> list:
        def work():
            fav = self.session.user.favorites
            if what == "tracks":
                return [track_dict(t) for t in fav.tracks(limit=1000)]
            if what == "albums":
                return [album_dict(a) for a in fav.albums(limit=500)]
            if what == "artists":
                return [artist_dict(a) for a in fav.artists(limit=500)]
            if what == "playlists":
                seen, out = set(), []
                # The v2 folders endpoint caps a page at 50, so let tidalapi paginate.
                for p in list(self.session.user.playlists()) + list(fav.playlists_paginated()):
                    if p.id not in seen:
                        seen.add(p.id)
                        out.append(playlist_dict(p))
                return out
            if what == "mixes":
                out = []
                for cat in self.session.mixes().categories or []:
                    for item in getattr(cat, "items", []) or []:
                        d = any_dict(item)
                        if d and d["kind"] == "mix":
                            out.append(d)
                return out
            raise ValueError(f"unknown collection {what!r}")
        return await asyncio.to_thread(work)

    async def load_liked(self):
        """Fetch every liked id once after sign-in (paginated: TIDAL caps pages)."""
        def work():
            fav = self.session.user.favorites
            return {
                "track": {str(t.id) for t in fav.tracks_paginated()},
                "album": {str(a.id) for a in fav.albums_paginated()},
                "artist": {str(a.id) for a in fav.artists_paginated()},
                "playlist": {str(p.id) for p in fav.playlists_paginated()},
            }
        self.liked = await asyncio.to_thread(work)
        self.liked_loaded = True
        self.liked_version += 1
        log.info("liked: %s", {k: len(v) for k, v in self.liked.items()})

    def is_liked(self, kind: str, item_id) -> bool:
        return str(item_id) in self.liked.get(kind, set())

    async def favorite(self, kind: str, item_id: str, on: bool | None = None) -> bool:
        """Like or unlike; `on=None` toggles. Returns the new liked state."""
        item_id = str(item_id)
        if on is None:
            on = not self.is_liked(kind, item_id)

        def work():
            fav = self.session.user.favorites
            fn = getattr(fav, ("add_" if on else "remove_") + kind)
            return bool(fn(item_id))
        if await asyncio.to_thread(work):
            (self.liked[kind].add if on else self.liked[kind].discard)(item_id)
            self.liked_version += 1
        return self.is_liked(kind, item_id)

    async def radio(self, track_id: str) -> list:
        def work():
            return [track_dict(t) for t in self.session.track(track_id).get_track_radio(limit=50)]
        return await asyncio.to_thread(work)

    async def radio_from(self, track_id: str, limit: int = 60) -> tuple[dict, list]:
        """The seed as TIDAL has it (with its BPM, which an old queue entry may
        lack) and its track radio. Falls back to the artist's radio when the
        track has none."""
        def work():
            seed = self.session.track(track_id)
            try:
                items = seed.get_track_radio(limit=limit)
            except Exception as e:
                log.info("no track radio for %s (%s); trying the artist's", track_id, e)
                items = seed.artist.get_radio(limit=limit) if getattr(seed, "artist", None) else []
            return track_dict(seed), [track_dict(t) for t in items]
        return await asyncio.to_thread(work)

    # ---- playback ----------------------------------------------------------

    async def stream(self, track_id: str, cache_dir: Path) -> dict:
        """Resolve a playable source for mpv: a direct URL, or a DASH manifest file."""
        def work():
            s = self.session.track(track_id).get_stream()
            info = {"quality": str(s.audio_quality), "bitDepth": s.bit_depth,
                    "sampleRate": s.sample_rate, "replayGain": s.track_replay_gain}
            m = s.get_stream_manifest()
            info["codec"] = str(m.get_codecs() or "")
            if s.is_mpd:
                path = cache_dir / f"{track_id}.mpd"
                path.write_text(s.get_manifest_data())
                info["source"] = str(path)
                info["dash"] = True
                if m.dash_info and m.dash_info.audio_sampling_rate:
                    info["sampleRate"] = m.dash_info.audio_sampling_rate
            else:
                info["source"] = m.get_urls()[0]
                info["dash"] = False
            return info
        return await asyncio.to_thread(work)
