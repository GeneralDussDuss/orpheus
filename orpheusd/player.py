"""Playback for Orpheus: a queue on top of one long-lived mpv process.

mpv is driven over its JSON IPC socket. The next track is resolved and
appended to mpv's own playlist while the current one plays, so album
transitions are gapless.
"""

import asyncio
import json
import logging
import os
import random
import time
from pathlib import Path

from . import eq as eqmod
from .system import WINDOWS, mpv_path, ipc_address, ipc_clear, ipc_connect

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


def _title_option(track: dict) -> str:
    """What the system media overlay shows, as a loadfile option. Length-quoted
    (%n%), because titles carry the commas and equals signs that separate options."""
    t = " — ".join(x for x in (", ".join(track.get("artists") or []), track.get("title") or "") if x)
    return f"force-media-title=%{len(t.encode())}%{t}" if t else ""

# The caps above did not stop it. Sampled from 2026-10-24 to 10-27, mpv's
# anonymous heap grows about 4 MB per minute of playback, mostly in steps at
# track changes, flat while paused, and is only returned when the process
# exits (1.2 GB -> 90 MB). Rather than chase that inside mpv, the process is
# recycled at a track change once it is over budget: the next track is not
# prefetched, so the change is a plain load into a fresh mpv. One transition
# every couple of hours loses gapless; nothing else notices.
RECYCLE_MB = int(os.environ.get("ORPHEUS_RECYCLE_MB", "600"))


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
        }

    # ---- mpv process & IPC ---------------------------------------------------

    async def start(self):
        ipc_clear(self.socket_path)
        self._proc = await asyncio.create_subprocess_exec(
            mpv_path(), *MPV_ARGS, f"--input-ipc-server={self.socket_path}",
            stdin=asyncio.subprocess.DEVNULL, stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.DEVNULL)
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
            asyncio.create_task(self._prefetch_next())
        elif ev == "end-file":
            reason = msg.get("reason")
            if reason == "error":
                self.error = "Couldn't play this track, skipping"
                log.warning("mpv failed on entry %s: %s", msg.get("playlist_entry_id"), msg.get("file_error"))
                if msg.get("playlist_entry_id") == self._current_entry:
                    asyncio.create_task(self._advance_after_error())
            elif reason == "eof" and msg.get("playlist_entry_id") == self._current_entry:
                # mpv moves on by itself when the next track was prefetched; if not, we do.
                await asyncio.sleep(0.05)
                if self._current_entry == msg.get("playlist_entry_id"):
                    nxt = self.next_pos()
                    if nxt >= 0:
                        await self._load(nxt)
                    else:
                        self.paused = True
                        self.on_change()
        elif ev == "seek" or ev == "playback-restart":
            await self._refresh_position()
        elif ev == "client-message" and msg.get("args", [None])[0] == "orpheus":
            # Next / previous from the system media controls, through our queue.
            action = (msg.get("args") + [""])[1]
            if action == "next":
                await self.next()
            elif action == "previous":
                await self.previous()

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
        self.on_change()
        try:
            info = await self._resolve(track)
        except Exception as e:
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
        self._start_at = start
        opts = ",".join(o for o in (f"start={start:.2f}" if start else "",
                                    _title_option(self.queue[self.order[order_pos]])) if o)
        data = await self._send(["loadfile", info["source"], "replace", -1, opts])
        entry = (data or {}).get("playlist_entry_id", -1)
        self._entries[entry] = order_pos
        self._entry_info[entry] = self.stream_info
        self._current_entry = entry
        if start:
            # start-file usually lands before this reply and is skipped as an
            # unknown entry, so the clock is set here as well.
            self._pos_at, self._pos_clock = start, time.monotonic()
        await self._send(["set_property", "pause", paused])

    async def _prefetch_next(self):
        nxt = self.next_pos()
        if nxt < 0 or nxt == self.pos:
            return
        if self._heap_mb() > RECYCLE_MB:
            return  # let this track end into a plain load, and recycle there
        token = self._loading
        try:
            info = await self._resolve(self.queue[self.order[nxt]])
        except Exception:
            return
        if token != self._loading:
            return
        # Drop anything already queued in mpv after the current entry, then append.
        await self._send(["playlist-clear"])
        data = await self._send(["loadfile", info["source"], "append", -1,
                                 _title_option(self.queue[self.order[nxt]])])
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
                "shuffle": self.shuffle, "repeat": self.repeat, "position": round(self.position, 2),
                "playing": self.playing}

    async def restore(self, snap: dict):
        """Rebuild the queue and pick up at the saved position."""
        queue, order, pos = snap.get("queue") or [], snap.get("order") or [], int(snap.get("pos", -1))
        # It runs in the background, so anything played first wins.
        if self.queue or not queue or not (0 <= pos < len(order)):
            return
        # Idle mpv reports unpaused; say paused now, or the title shows with a
        # play state for the moment before the paused load lands.
        if not snap.get("playing"):
            self.paused = True
        self.queue, self.order, self.context = queue, order, snap.get("context") or {}
        self.shuffle, self.repeat = bool(snap.get("shuffle")), snap.get("repeat") or "off"
        at = float(snap.get("position") or 0)
        await self._load(pos, start=at if at > 2 else 0, paused=not snap.get("playing"))

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
        if self.idle and self.current:
            return await self._load(self.pos)
        await self._send(["cycle", "pause"])

    async def set_paused(self, paused: bool):
        if not paused and self.idle and self.current:
            return await self._load(self.pos)
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
        await self._send(["seek", max(0.0, float(seconds)), "absolute"])
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
        await self._send(["set_property", "volume", max(0.0, min(130.0, float(vol)))])

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
