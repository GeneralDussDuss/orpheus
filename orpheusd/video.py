"""The video window: a second mpv, with pixels.

Putting video inside the player window would mean a C++ Quickshell item over
libmpv's render API, which is a different project entirely. mpv's own window is
already GPU-direct and already good, so Orpheus drives it instead of
reimplementing it: the library is the remote, this is the screen. A Hyprland
rule on the window title decides where it lands.

It is a separate mpv from the music player deliberately. One process cannot be
both the audio pipeline feeding the visualiser and a video window without being
torn down and rebuilt on every switch between them.
"""

from __future__ import annotations

import asyncio
import json
import logging
from pathlib import Path

from .system import mpv_path, WINDOWS, ipc_address, ipc_clear, ipc_connect
from .youtube import VIDEO_FORMAT, YouTube, watch_url, ytdlp_path

log = logging.getLogger("orpheus.video")

VIDEO_ARGS = [
    "--no-terminal",
    "--idle=yes",            # the window stays up between videos
    "--force-window=yes",    # ... and appears immediately, before the stream resolves
    "--keep-open=no",
    # The window opens at its final size, and mpv must not undo it.
    "--auto-window-resize=no",
    "--title=Orpheus ╱╱ ${media-title}",
    f"--ytdl-format={VIDEO_FORMAT}",
]
if not WINDOWS:
    # Our own app id, so Hyprland places this window by its rule, not mpv's
    # generic one. A Windows mpv has no such option and would refuse to start.
    VIDEO_ARGS.append("--wayland-app-id=orpheus.video")


class Video:
    def __init__(self, runtime_dir: Path, on_change):
        self.socket_path = ipc_address(runtime_dir, "orpheus-video")
        self.on_change = on_change
        self.entry: dict | None = None
        self.paused = False
        self.duration = 0.0
        self.position = 0.0
        self._proc = None
        self._reader = None
        self._writer = None
        self._req = 0
        self._pending: dict[int, asyncio.Future] = {}
        self._youtube = YouTube()

    @property
    def running(self) -> bool:
        return self._proc is not None and self._proc.returncode is None

    def state(self) -> dict:
        return {
            "running": self.running,
            "entry": self.entry,
            "paused": self.paused,
            "position": round(self.position, 2),
            "duration": round(self.duration, 2),
        }

    # ---- process -----------------------------------------------------------

    async def _ensure(self):
        if self.running:
            return
        ipc_clear(self.socket_path)
        args = list(VIDEO_ARGS)
        ytdlp = ytdlp_path()
        if ytdlp:
            # For pages handed straight to mpv (not YouTube's: see `watch`): its
            # hook looks on PATH and in its config folder, and a winget install
            # is in neither until a new shell.
            args.append(f"--script-opts=ytdl_hook-ytdl_path={ytdlp}")
        self._proc = await asyncio.create_subprocess_exec(
            mpv_path(), *args, f"--input-ipc-server={self.socket_path}",
            stdin=asyncio.subprocess.DEVNULL, stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.DEVNULL)
        self._reader, self._writer = await ipc_connect(self.socket_path)
        asyncio.create_task(self._read_loop())
        for i, prop in enumerate(["pause", "duration", "time-pos"]):
            await self._send(["observe_property", i + 1, prop], wait=False)

    async def _send(self, command, wait=True):
        if not self.running or self._writer is None:
            return None
        self._req += 1
        rid = self._req
        fut = asyncio.get_running_loop().create_future() if wait else None
        if fut:
            self._pending[rid] = fut
        try:
            self._writer.write((json.dumps({"command": command, "request_id": rid}) + "\n").encode())
            await self._writer.drain()
        except (ConnectionResetError, BrokenPipeError):
            self._pending.pop(rid, None)
            return None
        if not fut:
            return None
        try:
            msg = await asyncio.wait_for(fut, 5)
        except asyncio.TimeoutError:
            self._pending.pop(rid, None)
            return None
        return msg.get("data")

    async def _read_loop(self):
        while True:
            try:
                line = await self._reader.readline()
            except (ConnectionResetError, BrokenPipeError):
                line = b""
            if not line:
                # The window was closed, by us or by whoever was watching.
                self.entry = None
                self.duration = self.position = 0.0
                self._proc = None
                self._writer = None
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
            if msg.get("event") == "end-file" and msg.get("reason") == "error":
                # Otherwise the window just stays black: say why somewhere.
                log.warning("video window could not play %s: %s",
                            (self.entry or {}).get("id", "?"), msg.get("file_error", "error"))
                continue
            if msg.get("event") == "property-change":
                name, data = msg.get("name"), msg.get("data")
                if name == "pause":
                    self.paused = bool(data)
                    self.on_change()
                elif name == "duration":
                    self.duration = float(data or 0)
                elif name == "time-pos":
                    self.position = float(data or 0)

    # ---- what it is for ----------------------------------------------------

    async def watch(self, entry: dict):
        """Show a YouTube video, starting the window if it is not already up.

        Raises YouTubeError when yt-dlp is missing or cannot resolve the page.
        """
        # The window first, so a click shows something while yt-dlp works.
        await self._ensure()
        page = entry.get("url") or watch_url(entry["id"])
        try:
            got = await self._youtube.video(page)
        except Exception as e:
            log.warning("video %s would not resolve: %s", entry.get("id"), e)
            raise
        entry = dict(entry, duration=entry.get("duration") or got["duration"])
        await self.play(got["url"], entry, got["options"])

    async def play(self, url: str, entry: dict, options: dict | None = None):
        """Show any stream the window can take.

        The options are mpv's own, applied to this file only: a scraped stream
        usually needs a referrer to be fetched at all, and may carry subtitles
        as a separate URL. `force-media-title` is what the window title - and so
        the Hyprland rule - ends up showing.
        """
        await self._ensure()
        self.entry = entry
        self.position = 0.0
        self.duration = float(entry.get("duration") or 0)
        opts = {k: v for k, v in (options or {}).items() if v}
        cmd = ["loadfile", url, "replace", 0, opts] if opts else ["loadfile", url, "replace"]
        await self._send(cmd, wait=False)
        await self._send(["set_property", "pause", False], wait=False)
        self.on_change()

    async def command(self, action: str, body: dict) -> bool:
        if not self.running:
            return False
        if action == "toggle":
            await self._send(["cycle", "pause"], wait=False)
        elif action == "pause":
            await self._send(["set_property", "pause", True], wait=False)
        elif action == "play":
            await self._send(["set_property", "pause", False], wait=False)
        elif action == "seek":
            await self._send(["seek", float(body.get("position", 0)), "absolute"], wait=False)
        elif action == "fullscreen":
            await self._send(["cycle", "fullscreen"], wait=False)
        elif action == "close":
            await self.close()
        else:
            return False
        return True

    async def pause(self):
        """Used when the music player takes over: never two things at once."""
        if self.running and not self.paused:
            await self._send(["set_property", "pause", True], wait=False)

    async def close(self):
        if not self.running:
            return
        try:
            await self._send(["quit"], wait=False)
            await asyncio.wait_for(self._proc.wait(), 2)
        except Exception:
            if self._proc:
                self._proc.kill()
        self.entry = None
        self._proc = None
        self.on_change()
