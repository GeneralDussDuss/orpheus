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
import glob
import json
import logging
import os
import re
import shutil
import time

from .system import WINDOWS

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
# YouTube's TV clients now gate a stream behind its pre-roll: the signed URL
# answers 403 until `available_at`, a few seconds after extraction. yt-dlp's own
# downloader waits it out; anything handed the URL directly has to as well.
# A wait longer than this is not an ad, and is not worth holding a request for.
MAX_GATE_WAIT = 30


def ytdlp_path() -> str | None:
    """yt-dlp on PATH, or where winget puts it: winget only reaches PATH in a new
    shell, and a daemon not started by the desktop app never gets the folder
    `find_tools` adds. ORPHEUS_YTDLP overrides both."""
    found = os.environ.get("ORPHEUS_YTDLP") or shutil.which("yt-dlp")
    if found or not WINDOWS:
        return found
    local = os.environ.get("LOCALAPPDATA", "")
    for pattern in (rf"{local}\Microsoft\WinGet\Links\yt-dlp.exe",
                    rf"{local}\Microsoft\WinGet\Packages\*yt-dlp.yt-dlp*\**\yt-dlp.exe",
                    rf"{os.environ.get('USERPROFILE', '')}\scoop\shims\yt-dlp.exe",
                    rf"{os.environ.get('ProgramData', '')}\chocolatey\bin\yt-dlp.exe"):
        hits = glob.glob(pattern, recursive=True)
        if hits:
            return hits[0]
    return None


MISSING = ("yt-dlp is not installed or not on PATH "
           "(winget install --id yt-dlp.yt-dlp -e), or set ORPHEUS_YTDLP")


async def until_available(available_at, what: str) -> None:
    """Sleep out a stream's ad gate, so its first request is not a 403."""
    try:
        wait = float(available_at) - time.time()
    except (TypeError, ValueError):
        return
    if wait > 0:
        log.info("%s is gated for %.1fs; waiting", what, min(wait, MAX_GATE_WAIT))
        await asyncio.sleep(min(wait, MAX_GATE_WAIT))


def _edl(urls: list[str]) -> str:
    """Separate streams as one file, the way mpv's own ytdl hook joins them.
    Each URL is length-prefixed, so its `;` and `,` need no escaping."""
    return "edl://" + ";".join(
        f"!new_stream;!no_clip;!no_chapters;%{len(u.encode())}%{u}" for u in urls)


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
        exe = ytdlp_path()
        if not exe:
            log.error(MISSING)
            raise YouTubeError(MISSING)
        try:
            proc = await asyncio.create_subprocess_exec(
                exe, *args,
                stdin=asyncio.subprocess.DEVNULL,
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        except OSError as e:
            log.error("yt-dlp at %s would not start: %s", exe, e)
            raise YouTubeError(MISSING)
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
                              "--print", "%(acodec)s|%(abr)s|%(asr)s|%(ext)s|%(available_at)s",
                              "--print", "urls", self.page(vid))
        lines = [l for l in out.splitlines() if l.strip()]
        if len(lines) < 2:
            raise YouTubeError("no audio stream for that video")
        codec, abr, asr, ext, gate = (lines[0].split("|") + ["", "", "", "", ""])[:5]
        await until_available(gate, f"{self.name} audio {vid}")

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

    async def video(self, url: str) -> dict:
        """What the video window loads for a page: a URL, and the mpv options
        it needs to be fetched.

        mpv's own ytdl hook could do this, but it loads the URLs the moment
        yt-dlp hands them over, and a gated stream answers that with a 403 and
        a black window. Resolving here lets the wait happen first.
        """
        out = await self._run("-J", "-f", VIDEO_FORMAT, "--no-warnings", "--no-playlist", url)
        try:
            data = json.loads(out)
        except json.JSONDecodeError:
            raise YouTubeError("could not read that video")
        formats = data.get("requested_formats") or [data]
        urls = [f.get("url") for f in formats]
        if not all(urls):
            raise YouTubeError("no playable stream for that video")
        await until_available(max((f.get("available_at") or 0) for f in formats),
                              f"{self.name} video {data.get('id') or url}")
        headers = dict(formats[0].get("http_headers") or {})
        options = {
            "user-agent": headers.pop("User-Agent", None),
            "referrer": headers.pop("Referer", None),
            "force-media-title": data.get("title"),
        }
        # Whatever else yt-dlp says the server wants. Commas would split the
        # list, and these headers are never more than accept-language noise.
        rest = [f"{k}: {v}" for k, v in headers.items() if "," not in f"{k}{v}"]
        if rest:
            options["http-header-fields"] = ",".join(rest)
        return {"url": urls[0] if len(urls) == 1 else _edl(urls),
                "duration": float(data.get("duration") or 0),
                "options": options}

    def forget(self, vid: str) -> None:
        """Drop a cached URL, so a failed play is retried properly."""
        self._streams.pop(vid, None)
