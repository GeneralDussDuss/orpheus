"""Synced lyrics: TIDAL first, LRCLIB as a fallback, parsed into timed lines.

The daemon parses LRC rather than handing the raw file to the interface. There
is only one correct way to read those timestamps and it has enough edge cases
(fractions of one to three digits, repeated timestamps on a line, word-level
tags, lines deliberately left empty for an instrumental gap) that doing it once
here beats doing it again in QML.

Nothing is written into the repo and no lyrics are bundled: they are fetched at
play time from the listener's own TIDAL subscription, or from LRCLIB, and cached
under ~/.cache/orpheus/lyrics.
"""

from __future__ import annotations

import json
import logging
import re
import time
from pathlib import Path

log = logging.getLogger("orpheus.lyrics")

LRCLIB = "https://lrclib.net/api/get"
UA = "Orpheus/0.1 (https://github.com/GeneralDussDuss/orpheus)"

# A miss is worth remembering for a while: plenty of tracks simply have no
# lyrics anywhere, and re-asking two services on every play is rude to both.
MISS_TTL = 7 * 24 * 3600

# Bumped when the shape of a cached entry changes - word timings were added in
# v2, and an entry from before that would silently keep the interface on the
# old whole-line behaviour for a week.
CACHE_V = 2

_TIME = re.compile(r"\[(\d+):(\d{1,2})(?:[.:](\d{1,3}))?\]")
_WORD = re.compile(r"<(\d+):(\d{1,2})(?:[.:](\d{1,3}))?>")
_OFFSET = re.compile(r"\[offset:\s*([+-]?\d+)\s*\]", re.I)


def _secs(mm: str, ss: str, frac: str | None) -> float:
    # "5" is five tenths, "50" is fifty hundredths: scale by the digits
    frac = frac or "0"
    return int(mm) * 60 + int(ss) + int(frac) / (10 ** len(frac))


def _split_words(body: str) -> tuple[str, list[dict]]:
    """A body with <mm:ss.xx> tags -> (clean text, [{t, a, b}]).

    A word tag says which syllable is being sung right now, which is what lets
    the interface fill a line in as it is sung instead of lighting the whole
    thing at once. The spans are character offsets into the clean text, so the
    interface never has to re-tokenise and disagree with us about where a word
    begins.
    """
    runs: list[tuple[float | None, str]] = []
    at, stamp = 0, None
    for m in _WORD.finditer(body):
        runs.append((stamp, body[at:m.start()]))
        stamp = _secs(m.group(1), m.group(2), m.group(3))
        at = m.end()
    runs.append((stamp, body[at:]))

    clean, spans = "", []
    for t, run in runs:
        if not run:
            continue
        start = len(clean)
        clean += run
        if t is not None:
            spans.append({"t": round(t, 3), "a": start, "b": len(clean)})

    # the text is stripped for display, so the offsets have to move with it
    lead = len(clean) - len(clean.lstrip())
    text = clean.strip()
    kept = []
    for s in spans:
        a, b = max(0, s["a"] - lead), min(len(text), s["b"] - lead)
        if b > a:
            kept.append({"t": s["t"], "a": a, "b": b})
    return text, kept


def parse_lrc(text: str) -> list[dict]:
    """LRC into [{t, text}], sorted by time.

    Lines with no timestamp are metadata and are dropped. A timestamped line
    with no words is kept: that is how an instrumental break is written, and
    dropping it would make the previous line hang on screen through it.
    """
    out: list[dict] = []
    for raw in (text or "").splitlines():
        stamps = list(_TIME.finditer(raw))
        if not stamps:
            continue
        body, words = _split_words(_TIME.sub("", raw))
        base = None
        for m in stamps:
            seconds = _secs(m.group(1), m.group(2), m.group(3))
            if base is None:
                base = seconds
            line = {"t": round(seconds, 3), "text": body}
            if words:
                # one set of word tags serves a line written at several times;
                # shift them onto each occurrence
                shift = seconds - base
                line["words"] = words if not shift else [
                    {"t": round(w["t"] + shift, 3), "a": w["a"], "b": w["b"]} for w in words
                ]
            out.append(line)
    out.sort(key=lambda line: line["t"])
    return out


def lrc_offset(text: str) -> float:
    """The file's own [offset:] tag, in seconds. Rare, but free to honour."""
    m = _OFFSET.search(text or "")
    if not m:
        return 0.0
    try:
        return int(m.group(1)) / 1000.0
    except ValueError:
        return 0.0


class Lyrics:
    def __init__(self, tidal, cache_dir: Path):
        self.tidal = tidal
        self.dir = cache_dir / "lyrics"
        self.dir.mkdir(parents=True, exist_ok=True)

    # ---- cache -------------------------------------------------------------

    def _path(self, track_id: str) -> Path:
        safe = re.sub(r"[^A-Za-z0-9_-]", "_", str(track_id))[:64]
        return self.dir / f"{safe}.json"

    def _cached(self, track_id: str) -> dict | None:
        try:
            data = json.loads(self._path(track_id).read_text())
        except Exception:
            return None
        if data.get("v") != CACHE_V:
            return None
        if data.get("source") == "none" and time.time() - data.get("at", 0) > MISS_TTL:
            return None
        return data

    def _store(self, track_id: str, data: dict) -> dict:
        data = dict(data, at=time.time(), v=CACHE_V)
        try:
            self._path(track_id).write_text(json.dumps(data))
        except Exception as e:
            log.debug("could not cache lyrics for %s: %s", track_id, e)
        return data

    # ---- sources -----------------------------------------------------------

    async def _from_tidal(self, track_id: str) -> dict | None:
        import asyncio

        def work():
            return self.tidal.session.track(track_id).lyrics()

        try:
            got = await asyncio.to_thread(work)
        except Exception as e:
            # A track with no lyrics raises, and so does a rate limit or a
            # network failure. Only the first is worth caching as a miss, so
            # let the caller tell them apart by name.
            name = type(e).__name__
            if name in ("MetadataNotAvailable", "ObjectNotFound"):
                return None
            log.debug("tidal lyrics for %s: %s: %s", track_id, name, e)
            raise

        synced = parse_lrc(getattr(got, "subtitles", "") or "")
        plain = (getattr(got, "text", "") or "").strip()
        if not synced and not plain:
            return None
        return {
            "source": "tidal",
            "synced": bool(synced),
            "lines": synced,
            "plain": plain,
            "offset": lrc_offset(getattr(got, "subtitles", "") or ""),
            "rtl": bool(getattr(got, "right_to_left", False)),
        }

    async def _from_lrclib(self, track: dict) -> dict | None:
        import aiohttp

        title = (track or {}).get("title") or ""
        artists = (track or {}).get("artists") or []
        artist = artists[0] if isinstance(artists, list) and artists else ""
        if isinstance(artist, dict):
            artist = artist.get("name", "")
        if not title or not artist:
            return None

        params = {"track_name": title, "artist_name": str(artist)}
        if track.get("album"):
            params["album_name"] = str(track["album"])
        if track.get("duration"):
            params["duration"] = str(int(track["duration"]))

        try:
            timeout = aiohttp.ClientTimeout(total=6)
            async with aiohttp.ClientSession(timeout=timeout, headers={"User-Agent": UA}) as s:
                async with s.get(LRCLIB, params=params) as r:
                    if r.status == 404:
                        return None
                    if r.status != 200:
                        log.debug("lrclib returned %s for %r", r.status, title)
                        return None
                    d = await r.json()
        except Exception as e:
            log.debug("lrclib lookup failed for %r: %s", title, e)
            return None

        if d.get("instrumental"):
            return {"source": "lrclib", "synced": False, "lines": [],
                    "plain": "", "offset": 0.0, "rtl": False, "instrumental": True}

        synced = parse_lrc(d.get("syncedLyrics") or "")
        plain = (d.get("plainLyrics") or "").strip()
        if not synced and not plain:
            return None
        return {
            "source": "lrclib",
            "synced": bool(synced),
            "lines": synced,
            "plain": plain,
            "offset": lrc_offset(d.get("syncedLyrics") or ""),
            "rtl": False,
        }

    # ---- the one entry point ----------------------------------------------

    async def get(self, track_id: str, track: dict | None = None) -> dict:
        cached = self._cached(track_id)
        if cached is not None:
            return cached

        empty = {"source": "none", "synced": False, "lines": [], "plain": "",
                 "offset": 0.0, "rtl": False}

        try:
            got = await self._from_tidal(track_id)
        except Exception:
            # transient: do not cache, so the next play tries again
            return empty
        if got and got["synced"]:
            return self._store(track_id, got)

        # TIDAL had nothing, or had only unsynced words. LRCLIB may have timings,
        # which are worth more than plain text we already hold.
        alt = await self._from_lrclib(track or {})
        if alt and alt.get("synced"):
            return self._store(track_id, alt)
        if got:
            return self._store(track_id, got)
        if alt:
            return self._store(track_id, alt)
        return self._store(track_id, empty)
