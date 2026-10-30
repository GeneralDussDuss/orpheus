"""Playback for Orpheus: a queue on top of one long-lived mpv process.

mpv is driven over its JSON IPC socket. The next track is resolved and
appended to mpv's own playlist while the current one plays, so album
transitions are gapless.
"""

import asyncio
import hashlib
import json
import logging
import os
import random
import time
from pathlib import Path

from . import eq as eqmod
from .system import WINDOWS, mpv_path, ipc_address, ipc_clear, ipc_connect, tie_to_daemon, write_atomic

log = logging.getLogger("orpheus.player")

MPV_ARGS = [
    "--idle=yes", "--no-video", "--no-terminal", "--audio-display=no",
    "--demuxer-lavf-o=protocol_whitelist=[file,http,https,tcp,tls,crypto,data]",
    "--gapless-audio=weak", "--prefetch-playlist=yes", "--cache=yes",
    # mpv's stock demuxer budget is 150 MiB forward + 50 MiB back, sized for
    # video. Prefetch means two demuxers are live at once, so audio-only
    # playback can sit on ~400 MiB of buffer it will never use: 48 MiB is
    # still ~80 s of hi-res FLAC. Measured 2026-10-24: after a 7 h session mpv
    # held 1.19 GB of anonymous heap, which these caps alone may not explain.
    "--demuxer-max-bytes=48MiB", "--demuxer-max-back-bytes=16MiB",
    "--replaygain=track", "--replaygain-clip=no", "--keep-open=no",
    "--audio-client-name=Orpheus", "--load-scripts=no",
    # On Linux the daemon is the MPRIS player, so mpv's own must stay off. Windows
    # has no MPRIS: there mpv's media controls are how the keyboard's media keys
    # and the system media overlay reach Orpheus.
    f"--media-controls={'yes' if WINDOWS else 'no'}",
]


def _q(s: str) -> str:
    """mpv's length quoting (%n%text), for values that carry the commas, equals
    signs and semicolons that separate loadfile options and EDL fields."""
    return f"%{len(s.encode())}%{s}"


def _loadable(source: str, track: dict, cover: str = "") -> tuple[str, str]:
    """The URL and loadfile options that play `source` as `track`.

    On Windows, mpv's media controls fill the system media overlay and lock
    screen from mpv's own state (osdep/win32/smtc.cpp): the title from
    media-title, artist and album from metadata/by-key/Artist and /Album, and
    the thumbnail from the first external image track in track-list. A TIDAL
    stream carries none of that, so the source is wrapped in a one-segment EDL
    whose !global_tags supply the metadata, and the cover, already downloaded,
    is attached with cover-art-files. --no-video keeps that track unselected,
    so it is never decoded. On Linux the daemon is the MPRIS player and mpv's
    metadata is never shown, so the source goes in untouched."""
    title = track.get("title") or ""
    artist = ", ".join(track.get("artists") or [])
    if not WINDOWS:
        t = " — ".join(x for x in (artist, title) if x)
        return source, f"force-media-title={_q(t)}" if t else ""
    tags = ",".join(f"{k}={_q(v)}" for k, v in
                    (("title", title), ("artist", artist), ("album", track.get("album") or "")) if v)
    url = f"edl://!global_tags,{tags};{_q(source)}" if tags else source
    opts = [f"force-media-title={_q(title)}" if title else "",
            f"cover-art-files={_q(cover)}" if cover else ""]
    return url, ",".join(o for o in opts if o)

# The caps above did not stop it. Sampled from 2026-10-24 to 10-27, mpv's
# anonymous heap grows about 4 MB per minute of playback, mostly in steps at
# track changes, flat while paused, and is only returned when the process
# exits (1.2 GB -> 90 MB). Rather than chase that inside mpv, the process is
# recycled at a track change once it is over budget: the next track is not
# prefetched, so the change is a plain load into a fresh mpv. One transition
# every couple of hours loses gapless; nothing else notices.
RECYCLE_MB = int(os.environ.get("ORPHEUS_RECYCLE_MB", "600"))


def _prune(folder: Path, keep: int):
    """Keep the newest `keep` covers."""
    try:
        files = sorted(folder.glob("*.jpg"), key=lambda p: p.stat().st_mtime, reverse=True)
        for p in files[keep:]:
            p.unlink(missing_ok=True)
    except OSError:
        pass


class QueueStore:
    """The queue on disk, so a restarted daemon picks up where it left off.

    Two files, because they change at very different rates: queue.json holds
    the tracks (a 475-track playlist is about 160 KB) and is rewritten only
    when the queue, the current track or the play modes change; place.json
    holds where in the current track we are and is rewritten every few
    seconds of playback. Both are written atomically. The desktop app stops
    the daemon with TerminateProcess, so there is no reliable last chance to
    save: what is on disk is at most a few seconds behind, and a clean
    shutdown writes both once more."""

    PLACE_EVERY = 5.0

    def __init__(self, state_dir: Path, player: "Player"):
        self.queue_path = state_dir / "queue.json"
        self.place_path = state_dir / "place.json"
        self.legacy_path = state_dir / "resume.json"
        self.player = player
        self._key = None
        self._place: dict | None = None
        self._task = None

    def load(self) -> dict | None:
        """The saved queue with the latest place folded in, or None."""
        snap = None
        for path in (self.queue_path, self.legacy_path):
            try:
                snap = json.loads(path.read_text(encoding="utf-8"))
            except FileNotFoundError:
                continue
            except Exception as e:
                log.warning("ignoring unreadable %s: %s", path.name, e)
                snap = None
                continue
            if isinstance(snap, dict):
                break
            snap = None
        if snap is None:
            return None
        try:
            place = json.loads(self.place_path.read_text(encoding="utf-8"))
            order, queue = snap.get("order") or [], snap.get("queue") or []
            pos = int(place["pos"])
            # Trust the place only if it points at the track it says it does.
            if (0 <= pos < len(order) and 0 <= order[pos] < len(queue)
                    and queue[order[pos]].get("id") == place.get("id")):
                snap["pos"], snap["position"] = pos, place.get("position", 0)
        except Exception:
            pass
        return snap

    def mark_saved(self):
        """What is in the player now came from disk: no need to write it back."""
        self._key = self.player.queue_key()
        self._place = self.player.place()

    def poke(self):
        """Called on every player change; saves at most once a second."""
        if self._task is None or self._task.done():
            self._task = asyncio.create_task(self._later())

    async def _later(self):
        await asyncio.sleep(1.0)
        try:
            await self.save()
        except Exception as e:
            log.warning("couldn't save the queue: %s", e)

    def _place_due(self, place: dict) -> bool:
        last = self._place
        if last is None or (last["pos"], last["id"], last["paused"]) != (place["pos"], place["id"], place["paused"]):
            return True
        if place["paused"]:
            return place["position"] != last["position"]   # a seek while paused
        return abs(place["position"] - last["position"]) >= self.PLACE_EVERY

    def _queue_bytes(self) -> bytes:
        return json.dumps(dict(self.player.snapshot(), version=1), separators=(",", ":")).encode()

    async def save(self):
        p = self.player
        if not p.queue:
            return
        key, place = p.queue_key(), p.place()
        if key != self._key:
            # Serialised here, on the loop, so the lists cannot change under it.
            await asyncio.to_thread(write_atomic, self.queue_path, self._queue_bytes())
            self._key = key
        if self._place_due(place):
            await asyncio.to_thread(write_atomic, self.place_path, json.dumps(place).encode())
            self._place = place

    def save_now(self):
        """Synchronous, for a clean shutdown."""
        if not self.player.queue:
            return
        write_atomic(self.queue_path, self._queue_bytes())
        write_atomic(self.place_path, json.dumps(self.player.place()).encode())


class Player:
    def __init__(self, tidal, sources: dict, runtime_dir: Path, cache_dir: Path, on_change):
        self.tidal = tidal
        # yt-dlp sources by provider name; a track without a provider is TIDAL's
        self.sources = sources
        self.socket_path = ipc_address(runtime_dir, "mpv")
        self.cache_dir = cache_dir
        self.on_change = on_change

        self.queue: list[dict] = []
        self.order: list[int] = []        # play order (indices into queue); shuffled or not
        self.pos = -1                     # position within order
        self.context: dict = {}
        self.shuffle = False
        self.repeat = "off"               # off | all | one
        self.paused = True
        self.idle = True
        self.duration = 0.0
        self._start_at = 0.0              # where the next loaded file opens
        self._pos_at = 0.0                # last known time-pos ...
        self._pos_clock = time.monotonic()  # ... and when we learned it
        self.volume = 100.0
        self.stream_info: dict = {}
        self.error = ""
        self.eq: dict = eqmod.normalize(None)
        self._eq_chain = ""

        self._proc = None
        self._clock_task = None
        self._reader = None
        self._writer = None
        self._req = 0
        self._pending: dict[int, asyncio.Future] = {}
        self._entries: dict[int, int] = {}   # mpv playlist_entry_id -> order position
        self._entry_info: dict[int, dict] = {}  # mpv playlist_entry_id -> stream info
        self._current_entry = -1
        self._loading = 0                    # bumps on every user-initiated load
        # A load runs from _load() until mpv reports the file loaded. A seek in
        # that window would reach the previous file, or an idle mpv, and be
        # lost; it is parked here and applied once the new file is in.
        self._busy = False
        self._load_entry = None              # the entry _load() handed mpv
        self._last_started = None            # last start-file's entry ...
        self._last_loaded = None             # ... and the last one that loaded
        self._seek_after_load = None
        # Where play picks up when mpv is idle with a current track: a queue
        # restored at startup, or an idle seek. Nothing is resolved until play,
        # since TIDAL's stream URLs expire.
        self._resume_at = 0.0
        self._http = None

    # ---- derived -----------------------------------------------------------

    @property
    def current(self) -> dict | None:
        if 0 <= self.pos < len(self.order):
            return self.queue[self.order[self.pos]]
        return None

    @property
    def position(self) -> float:
        if self.paused or self.idle:
            return self._pos_at
        return min(self.duration or 1e9, self._pos_at + time.monotonic() - self._pos_clock)

    @property
    def playing(self) -> bool:
        return not self.paused and not self.idle and self.current is not None

    def next_pos(self, manual=False) -> int:
        if not self.order:
            return -1
        if self.repeat == "one" and not manual:
            return self.pos
        if self.pos + 1 < len(self.order):
            return self.pos + 1
        return 0 if self.repeat == "all" else -1

    def state(self) -> dict:
        cur = self.current
        upcoming = []
        for i in range(self.pos + 1, min(len(self.order), self.pos + 51)):
            upcoming.append(self.queue[self.order[i]])
        return {
            "track": cur,
            "playing": self.playing,
            "paused": self.paused,
            "position": round(self.position, 2),
            "duration": round(self.duration or (cur["duration"] if cur else 0), 2),
            "volume": round(self.volume),
            "shuffle": self.shuffle,
            "repeat": self.repeat,
            "context": self.context,
            "stream": self.stream_info,
            "queueIndex": self.pos,
            "queueLength": len(self.order),
            "upNext": upcoming,
            "error": self.error,
            # The desktop's audio capture listens to this process tree only.
            "mpvPid": self._proc.pid if self._proc and self._proc.returncode is None else 0,
        }

    # ---- mpv process & IPC ---------------------------------------------------

    async def start(self):
        ipc_clear(self.socket_path)
        self._proc = await asyncio.create_subprocess_exec(
            mpv_path(), *MPV_ARGS, f"--input-ipc-server={self.socket_path}",
            stdin=asyncio.subprocess.DEVNULL, stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.DEVNULL)
        try:
            tie_to_daemon(self._proc.pid)
        except OSError as e:
            log.warning("mpv will outlive a killed daemon: %s", e)
        self._reader, self._writer = await ipc_connect(self.socket_path)
        asyncio.create_task(self._read_loop(self._reader))
        for i, prop in enumerate(["pause", "duration", "idle-active", "volume", "playlist-pos"]):
            await self._send(["observe_property", i + 1, prop])
        if WINDOWS:
            # mpv would step through its own playlist, which only ever holds the
            # current and prefetched track; hand next/previous to the daemon instead.
            for key, action in (("NEXT", "next"), ("PREV", "previous")):
                await self._send(["keybind", key, f"script-message orpheus {action}"])
        # Restore the saved curve before anything plays, so the first track is
        # already corrected rather than snapping into place a moment later.
        await self._apply_eq()
        if not self._clock_task:
            self._clock_task = asyncio.create_task(self._clock_loop())

    def _heap_mb(self) -> int:
        try:
            with open(f"/proc/{self._proc.pid}/status") as f:
                for line in f:
                    if line.startswith("RssAnon:"):
                        return int(line.split()[1]) // 1024
        except (OSError, AttributeError, ValueError):
            pass
        return 0

    async def _recycle(self):
        mb, volume = self._heap_mb(), self.volume
        self._reader = None  # retire the old read loop before mpv says goodbye
        await self.stop()
        await self.start()
        await self._send(["set_property", "volume", volume])
        log.info("recycled mpv at %d MB of heap", mb)

    async def stop(self):
        if self._http is not None:
            await self._http.close()
            self._http = None
        if self._proc and self._proc.returncode is None:
            try:
                await self._send(["quit"], wait=False)
                await asyncio.wait_for(self._proc.wait(), 2)
            except Exception:
                self._proc.kill()

    async def _send(self, command, wait=True):
        self._req += 1
        rid = self._req
        fut = asyncio.get_running_loop().create_future() if wait else None
        if fut:
            self._pending[rid] = fut
        self._writer.write((json.dumps({"command": command, "request_id": rid}) + "\n").encode())
        await self._writer.drain()
        if not fut:
            return None
        try:
            msg = await asyncio.wait_for(fut, 5)
        except asyncio.TimeoutError:
            self._pending.pop(rid, None)
            return None
        if msg.get("error") not in (None, "success"):
            log.debug("mpv %s -> %s", command[0], msg.get("error"))
        return msg.get("data")

    async def _read_loop(self, reader):
        while True:
            try:
                line = await reader.readline()
            except (ConnectionResetError, BrokenPipeError):
                line = b""
            if reader is not self._reader:
                return  # an mpv we recycled on purpose: its last words are stale
            if not line:
                log.error("mpv went away")
                self.idle = True
                self.on_change()
                return
            try:
                msg = json.loads(line)
            except ValueError:
                continue
            rid = msg.get("request_id")
            if rid and rid in self._pending:
                fut = self._pending.pop(rid)
                if not fut.done():
                    fut.set_result(msg)
                continue
            await self._on_event(msg)

    async def _on_event(self, msg):
        # This runs on the read loop, which is also what delivers replies to
        # _send. Anything here that sends a command and waits for the answer
        # must go in a task: awaited inline it waits on itself, and every seek
        # or track end stalled all events for _send's 5 s timeout.
        ev = msg.get("event")
        log.debug("mpv %s %s %s", ev, msg.get("name") or msg.get("reason") or "",
                  msg.get("data") if ev == "property-change" else msg.get("playlist_entry_id", ""))
        if ev == "property-change":
            name, data = msg.get("name"), msg.get("data")
            if name == "pause":
                self._sync_clock()
                self.paused = bool(data)
            elif name == "duration":
                self.duration = float(data or 0)
            elif name == "idle-active":
                self.idle = bool(data)
            elif name == "volume" and data is not None:
                self.volume = float(data)
            self.on_change()
        elif ev == "start-file":
            entry = msg.get("playlist_entry_id")
            self._last_started = entry
            if entry in self._entries:
                self._current_entry = entry
                self.pos = self._entries[entry]
                # A paused start sends no playback-restart to correct this later.
                self._pos_at, self._pos_clock = self._start_at, time.monotonic()
                self._start_at = 0.0
                self.duration = float((self.current or {}).get("duration") or 0)
                if entry in self._entry_info:
                    self.stream_info = self._entry_info[entry]
                self.on_change()
        elif ev == "file-loaded":
            self.error = ""
            self._last_loaded = self._last_started
            self._check_loaded()
            asyncio.create_task(self._prefetch_next())
        elif ev == "end-file":
            reason = msg.get("reason")
            if reason == "error":
                if msg.get("playlist_entry_id") == self._load_entry:
                    self._busy, self._seek_after_load = False, None
                self.error = "Couldn't play this track, skipping"
                log.warning("mpv failed on entry %s: %s", msg.get("playlist_entry_id"), msg.get("file_error"))
                if msg.get("playlist_entry_id") == self._current_entry:
                    asyncio.create_task(self._advance_after_error())
            elif reason == "eof" and msg.get("playlist_entry_id") == self._current_entry:
                asyncio.create_task(self._after_eof(msg.get("playlist_entry_id")))
        elif ev == "seek" or ev == "playback-restart":
            asyncio.create_task(self._refresh_position())
        elif ev == "client-message" and msg.get("args", [None])[0] == "orpheus":
            # Next / previous from the system media controls, through our queue.
            action = (msg.get("args") + [""])[1]
            if action == "next":
                asyncio.create_task(self.next())
            elif action == "previous":
                asyncio.create_task(self.previous())

    async def _after_eof(self, entry):
        # mpv moves on by itself when the next track was prefetched; if not, we
        # do. The pause lets that start-file arrive (the read loop is free now).
        await asyncio.sleep(0.05)
        if self._current_entry == entry:
            nxt = self.next_pos()
            if nxt >= 0:
                await self._load(nxt)
            else:
                self.paused = True
                self.on_change()

    async def _refresh_position(self):
        t = await self._send(["get_property", "time-pos"])
        if t is not None:
            self._pos_at, self._pos_clock = float(t), time.monotonic()
            self.on_change()

    def _sync_clock(self):
        self._pos_at = self.position
        self._pos_clock = time.monotonic()

    async def _clock_loop(self):
        # Re-anchor the interpolated position every few seconds.
        while True:
            await asyncio.sleep(3)
            if self.playing:
                await self._refresh_position()

    # ---- loading -------------------------------------------------------------

    @staticmethod
    def _info(info: dict) -> dict:
        return {k: info.get(k) for k in ("quality", "bitDepth", "sampleRate", "codec")}

    async def _resolve(self, track: dict) -> dict:
        # The only place that knows a track has a service behind it. Everything
        # downstream - the queue, shuffle, the equaliser, MPRIS, the visualiser,
        # resume - works the same either way, because by here it is just a URL.
        source = self.sources.get(track.get("provider"))
        if source:
            return await source.stream(track["id"])
        return await self.tidal.stream(track["id"], self.cache_dir)

    async def _load(self, order_pos: int, start: float = 0, paused: bool = False):
        self._loading += 1
        token = self._loading
        self.pos = order_pos
        track = self.current
        self.error = ""
        self._busy, self._load_entry, self._seek_after_load = True, None, None
        self._resume_at = 0.0
        self._pos_at, self._pos_clock = start, time.monotonic()
        self.on_change()
        cover = asyncio.create_task(self._cover(track))
        try:
            info = await self._resolve(track)
        except Exception as e:
            cover.cancel()
            if token == self._loading:
                self._busy = False
            log.warning("stream for %s failed: %s", track["id"], e)
            source = self.sources.get(track.get("provider"))
            if source:
                # yt-dlp says something useful ("Video unavailable", "Private
                # video"); a generic line would throw that away. Drop the cached
                # URL too, so a retry actually re-resolves.
                source.forget(track["id"])
                self.error = str(e)
            else:
                self.error = "This track isn't available to stream"
            self.on_change()
            return await self._advance_after_error()
        cover = await cover
        if token != self._loading:
            return  # a newer request won
        self.stream_info = self._info(info)
        if self._heap_mb() > RECYCLE_MB:
            await self._recycle()
        self._entries.clear()
        self._entry_info.clear()
        await self._send(["playlist-clear"])
        # A resumed track opens where it left off and already paused, rather than
        # playing a moment from the top first. Pause stays a global property:
        # as a loadfile option it would be file-local, and mpv would restore the
        # old value when the file ends, pausing the next gapless track.
        if paused:
            await self._send(["set_property", "pause", True])
        if self._seek_after_load is not None:
            # Seeked while the stream was resolving: just open the file there.
            start, self._seek_after_load = self._seek_after_load, None
        self._start_at = start
        url, extra = _loadable(info["source"], track, cover)
        opts = ",".join(o for o in (f"start={start:.2f}" if start else "", extra) if o)
        data = await self._send(["loadfile", url, "replace", -1, opts])
        entry = (data or {}).get("playlist_entry_id", -1)
        self._entries[entry] = order_pos
        self._entry_info[entry] = self.stream_info
        self._current_entry = entry
        if start:
            # start-file usually lands before this reply and is skipped as an
            # unknown entry, so the clock is set here as well.
            self._pos_at, self._pos_clock = start, time.monotonic()
        await self._send(["set_property", "pause", paused])
        if token == self._loading:
            self._load_entry = entry
            self._check_loaded()  # file-loaded may already have come and gone

    def _check_loaded(self):
        """End the load window once mpv has the file, and apply a parked seek."""
        if not self._busy or self._load_entry is None or self._last_loaded != self._load_entry:
            return
        self._busy = False
        self._start_at = 0.0  # its start-file has been and gone
        if self._seek_after_load is not None:
            at, self._seek_after_load = self._seek_after_load, None
            asyncio.create_task(self._seek_now(at))

    async def _cover(self, track: dict) -> str:
        """The track's cover as a local file for the media overlay, or "".

        smtc.cpp would take a URL, but mpv opens external tracks synchronously
        while loading the file, so a slow image host would delay the music.
        Downloading here runs alongside the stream resolve instead, and a cover
        is fetched once per album."""
        url = track.get("art") or ""
        if not WINDOWS or not url.startswith(("http://", "https://")):
            return ""
        folder = self.cache_dir / "covers"
        path = folder / (hashlib.sha1(url.encode()).hexdigest()[:20] + ".jpg")
        if path.is_file():
            return str(path)
        try:
            import aiohttp
            if self._http is None or self._http.closed:
                self._http = aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=4))
            async with self._http.get(url) as r:
                r.raise_for_status()
                data = await r.read()
            if not data or len(data) > 8 << 20:
                return ""
            folder.mkdir(parents=True, exist_ok=True)
            await asyncio.to_thread(write_atomic, path, data)
            asyncio.get_running_loop().run_in_executor(None, _prune, folder, 400)
            return str(path)
        except Exception as e:
            log.debug("no cover for %s: %s", track.get("id"), e)
            return ""

    async def _prefetch_next(self):
        nxt = self.next_pos()
        if nxt < 0 or nxt == self.pos:
            return
        if self._heap_mb() > RECYCLE_MB:
            return  # let this track end into a plain load, and recycle there
        token = self._loading
        track = self.queue[self.order[nxt]]
        cover = asyncio.create_task(self._cover(track))
        try:
            info = await self._resolve(track)
        except Exception:
            cover.cancel()
            return
        cover = await cover
        if token != self._loading:
            return
        # Drop anything already queued in mpv after the current entry, then append.
        await self._send(["playlist-clear"])
        url, opts = _loadable(info["source"], track, cover)
        data = await self._send(["loadfile", url, "append", -1, opts])
        entry = (data or {}).get("playlist_entry_id")
        if entry is not None:
            self._entries = {k: v for k, v in self._entries.items() if k == self._current_entry}
            self._entries[entry] = nxt
            self._entry_info = {k: v for k, v in self._entry_info.items() if k == self._current_entry}
            self._entry_info[entry] = self._info(info)

    async def _advance_after_error(self):
        nxt = self.next_pos(manual=True)
        if nxt >= 0 and nxt != self.pos:
            await asyncio.sleep(0.4)
            await self._load(nxt)

    # ---- resume across restarts --------------------------------------------------

    def snapshot(self) -> dict:
        return {"queue": self.queue, "order": self.order, "pos": self.pos, "context": self.context,
                "shuffle": self.shuffle, "repeat": self.repeat, "position": round(self.position, 2)}

    def queue_key(self) -> tuple:
        """Changes whenever the saved queue would: the lists are replaced or
        resized on every edit, and the rest is plain state."""
        return (id(self.queue), len(self.queue), id(self.order), len(self.order), self.pos,
                id(self.context), self.shuffle, self.repeat)

    def place(self) -> dict:
        """Where in the queue we are: small, so it can be saved every few seconds."""
        cur = self.current
        return {"pos": self.pos, "id": cur and cur.get("id"), "position": round(self.position, 1),
                "paused": not self.playing}

    async def restore(self, snap: dict) -> bool:
        """Put a saved queue back, paused at the saved track and position.

        Nothing is resolved: the stream is fetched when play is pressed, so an
        expired URL is never an issue and startup does not wait on TIDAL."""
        queue = [t for t in (snap.get("queue") or []) if isinstance(t, dict) and t.get("id")]
        if self.queue or not queue:
            return False
        order = snap.get("order")
        if not (isinstance(order, list) and order
                and all(isinstance(i, int) and 0 <= i < len(queue) for i in order)):
            order = list(range(len(queue)))
        try:
            pos = int(snap.get("pos", 0))
        except (TypeError, ValueError):
            pos = 0
        pos = pos if 0 <= pos < len(order) else 0
        try:
            at = max(0.0, float(snap.get("position") or 0))
        except (TypeError, ValueError):
            at = 0.0
        self.queue, self.order, self.pos = queue, order, pos
        self.context = snap.get("context") if isinstance(snap.get("context"), dict) else {}
        self.shuffle = bool(snap.get("shuffle"))
        self.repeat = snap.get("repeat") if snap.get("repeat") in ("off", "all", "one") else "off"
        self.duration = float(self.current.get("duration") or 0)
        if self.duration and at >= self.duration - 1:
            at = 0.0
        self._resume_at = self._pos_at = at
        self._pos_clock = time.monotonic()
        # Idle mpv reports unpaused; make it agree, so the UI shows a play button.
        self.paused = True
        await self._send(["set_property", "pause", True])
        self.on_change()
        return True

    # ---- public controls -----------------------------------------------------

    def _build_order(self, start_index: int):
        idx = list(range(len(self.queue)))
        if self.shuffle:
            rest = [i for i in idx if i != start_index]
            random.shuffle(rest)
            self.order = [start_index] + rest
            return 0
        self.order = idx
        return start_index

    async def play_list(self, tracks: list[dict], index: int = 0, context: dict | None = None):
        tracks = [t for t in tracks if t.get("available", True)] or tracks
        if not tracks:
            return
        self.queue = list(tracks)
        self.context = context or {}
        index = max(0, min(index, len(self.queue) - 1))
        await self._load(self._build_order(index))

    async def jump(self, queue_pos: int):
        if 0 <= queue_pos < len(self.order):
            await self._load(queue_pos)

    async def toggle(self):
        if self.idle and self.current and not self._busy:
            return await self._load(self.pos, start=self._resume_at)
        await self._send(["cycle", "pause"])

    async def set_paused(self, paused: bool):
        if not paused and self.idle and self.current and not self._busy:
            return await self._load(self.pos, start=self._resume_at)
        await self._send(["set_property", "pause", paused])

    async def next(self):
        nxt = self.next_pos(manual=True)
        if nxt >= 0:
            await self._load(nxt)

    async def previous(self):
        if self.position > 4 or self.pos <= 0:
            return await self.seek(0)
        await self._load(self.pos - 1)

    async def seek(self, seconds: float):
        at = max(0.0, float(seconds))
        if self._busy or (self.idle and self.current):
            # Loading, or idle on a restored track: nothing in mpv to seek yet.
            # Remember it, and show it, until there is.
            if self._busy:
                self._seek_after_load = at
                self._start_at = at
            else:
                self._resume_at = at
            self._pos_at, self._pos_clock = at, time.monotonic()
            self.on_change()
            self._check_loaded()
            return
        await self._seek_now(at)

    async def _seek_now(self, at: float):
        await self._send(["seek", at, "absolute"])
        await self._refresh_position()

    # ---- equalizer ---------------------------------------------------------

    async def _apply_eq(self):
        """Push the current curve to mpv, skipping a no-op rebuild.

        Setting `af` rebuilds the audio filter graph, so only do it when the
        resulting chain actually differs from what mpv is already running.
        """
        chain = eqmod.build_chain(self.eq)
        if chain == self._eq_chain:
            return
        self._eq_chain = chain
        if self._writer is None:
            return
        try:
            await self._send(["set_property", "af", chain])
        except Exception as e:
            log.warning("could not apply EQ: %s", e)

    async def set_eq(self, state: dict) -> dict:
        self.eq = eqmod.normalize(state)
        await self._apply_eq()
        self.on_change()
        return self.eq_state()

    def eq_state(self) -> dict:
        s = dict(self.eq)
        s["preampEffective"] = eqmod.effective_preamp(self.eq)
        s["active"] = bool(self._eq_chain)
        return s

    async def set_volume(self, vol: float):
        vol = max(0.0, min(130.0, float(vol)))
        await self._send(["set_property", "volume", vol])
        # mpv's property-change event lands after this returns, so the reply the UI
        # gets (and the saved prefs) would still carry the old volume.
        self.volume = vol

    async def set_shuffle(self, on: bool):
        if on == self.shuffle:
            return
        self.shuffle = on
        cur = self.order[self.pos] if self.current else 0
        if self.queue:
            self.pos = self._build_order(cur)
        self.on_change()
        asyncio.create_task(self._prefetch_next())

    async def set_repeat(self, mode: str):
        if mode in ("off", "all", "one"):
            self.repeat = mode
            self.on_change()
            asyncio.create_task(self._prefetch_next())

    async def enqueue(self, tracks: list[dict], next_up: bool = False):
        if not self.queue:
            return await self.play_list(tracks)
        start = len(self.queue)
        self.queue.extend(tracks)
        new = list(range(start, len(self.queue)))
        at = self.pos + 1 if next_up else len(self.order)
        self.order[at:at] = new
        self.on_change()
        asyncio.create_task(self._prefetch_next())

    async def remove(self, queue_pos: int):
        if queue_pos <= self.pos or queue_pos >= len(self.order):
            return
        del self.order[queue_pos]
        self.on_change()
        asyncio.create_task(self._prefetch_next())
