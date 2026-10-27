"""YouTube as a second source for the same player.

Orpheus already owns a queue, an equaliser, a visualiser, a transport and a
resume file, so the cheapest way to play a video's sound is to hand the player
a URL and let everything downstream carry on as though it were a track. That is
most of what this module does: ask yt-dlp the questions a browser would ask,
and normalise the answers into the shape the rest of the daemon already speaks.

Nothing is downloaded and no API key is involved. Resolved googlevideo URLs are
deliberately never logged: they carry the listener's IP address and a signature
that is as good as a session for as long as it lasts.
"""

from __future__ import annotations

import asyncio
import datetime
import json
import logging
import re
import time

log = logging.getLogger("orpheus.youtube")

SEARCH_TTL = 15 * 60
# A resolved URL is signed and expires. Re-resolving costs about two seconds;
# an expired one costs a failed play, so the window is kept well short of the
# real lifetime rather than close to it.
STREAM_TTL = 30 * 60

_ID = re.compile(r"(?:v=|/shorts/|youtu\.be/|/embed/|/live/)([A-Za-z0-9_-]{11})")
_BARE_ID = re.compile(r"^[A-Za-z0-9_-]{11}$")

# Audio for the music player: one stream, no muxing, straight into the queue.
AUDIO_FORMAT = "bestaudio[acodec!=none]/best"
# A flat search carries no date at all: YouTube only ships the "3 weeks ago"
# line, and yt-dlp turns that into a timestamp only when asked. It is
# approximate by construction - every result lands on a whole week, month or
# year back from today - so the UI shows it as an age, which is what it is.
DATE_ARGS = ["--extractor-args", "youtubetab:approximate_date"]
# Video for the window: mpv's own ytdl hook merges the separate video and audio
# streams, which is work we would otherwise have to do ourselves.
VIDEO_FORMAT = "bestvideo[height<=?1080]+bestaudio/best[height<=?1080]/best"


def video_id(text: str) -> str | None:
    """A bare id, or the id inside any of the URL shapes YouTube hands out."""
    text = (text or "").strip()
    if _BARE_ID.match(text):
        return text
    m = _ID.search(text)
    return m.group(1) if m else None


def watch_url(vid: str) -> str:
    return "https://www.youtube.com/watch?v=" + vid


def thumbnail(e: dict) -> str:
    # thumbnails run small to large; the first one big enough for a row is
    # plenty, and the largest is a waste to fetch for a list
    art = ""
    for t in e.get("thumbnails") or []:
        if t.get("url"):
            art = t["url"]
            if (t.get("width") or 0) >= 320:
                break
    return art


class YouTubeError(RuntimeError):
    pass


class YouTube:
    """Every yt-dlp source is this class with a different name, search prefix
    and row shape: see `soundcloud.py`."""

    name = "youtube"
    SEARCH = "ytsearch"
    SEARCH_ARGS = DATE_ARGS

    def __init__(self):
        self._searches: dict[str, tuple[float, list[dict]]] = {}
        self._streams: dict[str, tuple[float, dict]] = {}

    async def _run(self, *args: str, timeout: float = 30) -> str:
        proc = await asyncio.create_subprocess_exec(
            "yt-dlp", *args,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        try:
            out, err = await asyncio.wait_for(proc.communicate(), timeout)
        except asyncio.TimeoutError:
            proc.kill()
            raise YouTubeError(f"{self.name} took too long to answer")
        if proc.returncode != 0:
            # yt-dlp's last stderr line is the one worth showing; the rest is
            # traceback and progress noise.
            lines = [l for l in err.decode(errors="replace").splitlines() if l.strip()]
            why = (lines[-1] if lines else "failed").replace("ERROR: ", "").strip()
            raise YouTubeError(why[:200])
        return out.decode(errors="replace")

    # ---- shaping -----------------------------------------------------------

    @staticmethod
    def _entry(e: dict) -> dict:
        """One search result in the shape the player and the UI already use."""
        vid = e.get("id") or ""
        art = thumbnail(e)
        channel = e.get("channel") or e.get("uploader") or ""
        published = e.get("timestamp") or e.get("release_timestamp") or 0
        if not published and e.get("upload_date"):
            try:
                published = int(datetime.datetime.strptime(
                    e["upload_date"], "%Y%m%d").replace(tzinfo=datetime.timezone.utc).timestamp())
            except ValueError:
                published = 0
        live = (e.get("live_status") or "") in ("is_live", "is_upcoming")
        return {
            "kind": "track",
            "provider": "youtube",
            "id": vid,
            "title": e.get("title") or "untitled",
            "artists": [channel] if channel else [],
            "album": "",
            "duration": int(e.get("duration") or 0),
            "art": art,
            "views": int(e.get("view_count") or 0),
            "published": int(published or 0),
            "live": live,
            "url": watch_url(vid),
        }

    # ---- addressing --------------------------------------------------------

    def link(self, text: str) -> str | None:
        """The page a pasted link points at, or None when it is a search."""
        vid = video_id(text)
        return watch_url(vid) if vid else None

    def page(self, item_id: str) -> str:
        """What yt-dlp is handed to resolve a row it returned earlier."""
        return watch_url(item_id)

    # ---- asking ------------------------------------------------------------

    async def search(self, query: str, limit: int = 20) -> list[dict]:
        query = (query or "").strip()
        if not query:
            return []
        # A pasted link is not a search: it is someone handing you the answer.
        url = self.link(query)
        if url:
            return [await self.info(url)]

        key = f"{limit}:{query.lower()}"
        hit = self._searches.get(key)
        if hit and time.time() - hit[0] < SEARCH_TTL:
            return hit[1]
        out = await self._run("--flat-playlist", "-J", "--no-warnings", *self.SEARCH_ARGS,
                              f"{self.SEARCH}{int(limit)}:{query}")
        try:
            data = json.loads(out)
        except json.JSONDecodeError:
            raise YouTubeError("could not read the search result")
        items = [self._entry(e) for e in (data.get("entries") or []) if e.get("id")]
        self._searches[key] = (time.time(), items)
        return items

    async def info(self, url: str) -> dict:
        out = await self._run("-J", "--no-warnings", "--no-playlist", url)
        try:
            return self._entry(json.loads(out))
        except json.JSONDecodeError:
            raise YouTubeError("could not read that video")

    async def stream(self, vid: str) -> dict:
        """An audio URL for the music player, in `Player._resolve`'s shape."""
        hit = self._streams.get(vid)
        if hit and time.time() - hit[0] < STREAM_TTL:
            return hit[1]
        out = await self._run("-f", AUDIO_FORMAT, "--no-warnings", "--no-playlist",
                              "--print", "%(acodec)s|%(abr)s|%(asr)s|%(ext)s",
                              "--print", "urls", self.page(vid))
        lines = [l for l in out.splitlines() if l.strip()]
        if len(lines) < 2:
            raise YouTubeError("no audio stream for that video")
        codec, abr, asr, ext = (lines[0].split("|") + ["", "", "", ""])[:4]

        def num(v):
            try:
                return int(round(float(v)))
            except (TypeError, ValueError):
                return None

        rate = num(asr)
        kbps = num(abr)
        info = {
            # mpv loads this; it is never logged
            "source": lines[-1].strip(),
            # mp4a.40.2 is how the container spells AAC; nobody reads it that way
            "codec": "AAC" if codec.startswith("mp4a") else (codec if codec and codec != "none" else ext).upper(),
            "quality": f"{kbps}k" if kbps else "STREAM",
            "bitDepth": None,
            "sampleRate": rate,
        }
        self._streams[vid] = (time.time(), info)
        return info

    def forget(self, vid: str) -> None:
        """Drop a cached URL, so a failed play is retried properly."""
        self._streams.pop(vid, None)
