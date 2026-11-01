"""Drop-map analysis, managed: which tracks get analysed, when, and where the
maps live.

The player hands over every fresh resolve (Player.on_resolved): the current
track, and the next one when it is prefetched or put on a crossfade deck. A
TIDAL track whose map is not cached is queued (two at most: current, next) and
analysed by orpheusd/dropmap.py in a worker process, one at a time, at idle
priority with one thread and no window, so a game in the foreground keeps the
CPU. Maps go to CACHE_DIR/analysis/<key>.json, the key being provider, id and
the queue's whole-second duration. Failures are not cached; they are retried
after ten minutes, or sooner on a resolve with a fresh source.

Never imports numpy (the worker does), never awaits in schedule(), never logs
a stream source (TIDAL's are signed URLs or manifests that hold them).
"""
from __future__ import annotations

import asyncio
import hashlib
import json
import logging
import os
import re
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path

from .system import WINDOWS, write_atomic

log = logging.getLogger("orpheus.analysis")

MAX_SECONDS = 1200
FAIL_BACKOFF = 600
MAP_V = 1
DUR_SLACK = 3.0        # s: a decode this far from the queue's duration is another edition (or a preview)


def redact(s: str) -> str:
    """dropmap.redact, without importing the module that imports numpy."""
    return re.sub(r"https?://\S+", "<url>", s or "")


def key_of(track: dict | None) -> str | None:
    if not track or not track.get("id"):
        return None
    try:
        dur = int(float(track.get("duration") or 0))
    except (TypeError, ValueError):
        return None
    if dur <= 0:
        return None
    key = f"{track.get('provider') or 'tidal'}_{track['id']}_{dur}"
    return re.sub(r"[^A-Za-z0-9_-]", "_", key)[:80]


@dataclass
class Job:
    key: str
    track_id: str
    provider: str
    source: str
    dash: bool
    duration: float
    bpm: float
    role: str
    sig: str = ""                  # what the source looked like, to tell a fresh one from the one that failed
    proc: object = None
    started: float = 0.0
    mpd_copy: Path | None = None
    cancelled: bool = False


class Analysis:
    def __init__(self, cache_dir: Path, runtime_dir: Path, config, on_change, worker_cmd: list[str] | None = None,
                 ffmpeg: str | None = "auto"):
        try:
            from .system import ffmpeg_path, numpy_available
        except ImportError:           # a system.py without them: PATH and find_spec only
            import importlib.util
            import shutil
            ffmpeg_path = lambda: os.environ.get("ORPHEUS_FFMPEG") or shutil.which("ffmpeg")
            numpy_available = lambda: importlib.util.find_spec("numpy") is not None
        self.dir = Path(cache_dir) / "analysis"
        self.tmp = Path(runtime_dir) / "analysis"
        for d in (self.dir, self.tmp):
            d.mkdir(parents=True, exist_ok=True)
        self.config = config
        self.on_change = on_change
        self.ffmpeg = ffmpeg_path() if ffmpeg == "auto" else ffmpeg
        self.numpy = numpy_available()
        self.worker_cmd = worker_cmd or [sys.executable, "-m", "orpheusd.dropmap"]
        self.version = 0
        self._queue: list[Job] = []
        self._running: Job | None = None
        self._pump_task: asyncio.Task | None = None
        self._failed: dict[str, tuple[float, str, str]] = {}    # key -> (monotonic, error, source sig)
        self._state: dict[str, str] = {}                        # pending | ready | failed | none
        self._reason: dict[str, str] = {}
        self._current_key = ""
        self._next_key = ""
        self.last_ms = 0
        self.error = ""

    # ---- what can run --------------------------------------------------------

    @property
    def available(self) -> bool:
        return bool(self.ffmpeg) and self.numpy

    def on(self) -> bool:
        return self.config.get("dropMap") is not False

    def _path(self, key: str) -> Path:
        return self.dir / f"{key}.json"

    def cached(self, key: str) -> dict | None:
        try:
            data = json.loads(self._path(key).read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return None
        return data if isinstance(data, dict) and data.get("v") == MAP_V else None

    def skip_reason(self, track: dict) -> str | None:
        if not self.on():
            return "off"
        if not self.available:
            return "unavailable"
        if track.get("provider"):
            return "provider"
        if track.get("live"):
            return "live"
        try:
            dur = float(track.get("duration") or 0)
        except (TypeError, ValueError):
            dur = 0
        if dur <= 0:
            return "nodur"
        if dur > MAX_SECONDS:
            return "long"
        return None

    # ---- scheduling ----------------------------------------------------------

    def _set(self, key: str, state: str, reason: str = ""):
        self._state[key] = state
        if reason:
            self._reason[key] = reason
        else:
            self._reason.pop(key, None)

    def schedule(self, track: dict, info: dict, role: str) -> None:
        """A fresh resolve of `track` (role current | next). Sync, never raises."""
        try:
            self._schedule(track, info or {}, role)
        except Exception as e:
            log.debug("analysis schedule: %s", e)

    def _schedule(self, track: dict, info: dict, role: str):
        key = key_of(track)
        if not key:
            return
        if role == "current":
            self._current_key = key
        if self.cached(key):
            self._set(key, "ready")
            return self.bump()
        reason = self.skip_reason(track)
        if reason:
            self._set(key, "none", reason)
            return self.bump()
        source, dash = str(info.get("source") or ""), bool(info.get("dash"))
        if not source:
            return
        manifest = b""
        if dash:
            try:
                manifest = Path(source).read_bytes()      # ~3 KB; tidal.py rewrites it on every resolve
            except OSError as e:
                log.debug("analysis %s: no manifest (%s)", key, e.strerror)
                return
        sig = hashlib.sha1(manifest or source.encode()).hexdigest()
        failed = self._failed.get(key)
        if failed and time.monotonic() - failed[0] < FAIL_BACKOFF and failed[2] == sig:
            self._set(key, "failed")
            return self.bump()

        mine = [j for j in self._queue if j.key == key]
        running = self._running and self._running.key == key and not self._running.cancelled
        if running or mine:
            if role == "current" and mine:
                self._queue = mine[:1] + [j for j in self._queue if j.key != key]
            return
        if role == "current":
            # The current track wins: what was queued as current for another
            # track is stale, and a running job for anything but the next one stops.
            self._queue = [j for j in self._queue if j.role != "current"]
            if self._running and self._running.key not in (key, self._next_key):
                self._kill(self._running)

        job = Job(key, str(track["id"]), "tidal", source, dash, float(track.get("duration") or 0),
                  float(track.get("bpm") or 0), role, sig)
        if dash:
            job.mpd_copy = self.tmp / f"{key}-{time.monotonic_ns()}.mpd"   # a dying job for the same key unlinks only its own
            try:
                job.mpd_copy.write_bytes(manifest)
            except OSError as e:
                log.debug("analysis %s: manifest copy failed (%s)", key, e.strerror)
                return
            job.source = str(job.mpd_copy)
        if role == "current":
            self._queue.insert(0, job)
        else:
            self._queue.append(job)
        for dropped in self._queue[2:]:
            self._forget(dropped)
        self._queue = self._queue[:2]
        self._set(key, "pending")
        self.bump()
        if self._pump_task is None or self._pump_task.done():
            self._pump_task = asyncio.get_running_loop().create_task(self._pump())

    def retarget(self, current_key: str | None, next_key: str | None) -> None:
        """The player's current and next tracks now (every 0.5 s): anything
        queued or running for another track stops; all of it when switched off."""
        self._next_key = next_key or ""
        moved = bool(current_key) and current_key != self._current_key
        if moved:                       # a gapless or crossfade move never goes through _load
            self._current_key = current_key
        want = {k for k in (current_key, next_key) if k} if self.on() else set()
        gone = [j for j in self._queue if j.key not in want]
        if gone:
            self._queue = [j for j in self._queue if j.key in want]
            for j in gone:
                self._forget(j)
        if self._running and self._running.key not in want:
            self._kill(self._running)
        if gone or moved:
            self.bump()

    def _forget(self, job: Job):
        """A job that will not run: its state goes back to unknown."""
        if self._state.get(job.key) == "pending":
            self._state.pop(job.key, None)
        self._unlink(job)

    # ---- reading -------------------------------------------------------------

    async def get(self, track_id, provider, duration) -> dict:
        track = {"id": str(track_id), "duration": duration}
        if provider and provider != "tidal":
            track["provider"] = provider
        key = key_of(track)
        if not key:
            return {"state": "none", "key": "", "reason": "nodur"}
        data = await asyncio.to_thread(self.cached, key)
        if data:
            return data
        state = self._state.get(key)
        if state == "pending":
            return {"state": "pending", "key": key}
        if state == "failed":
            return {"state": "failed", "key": key, "error": self._failed.get(key, (0, self.error, ""))[1]}
        reason = self._reason.get(key) or self.skip_reason(track) or "unscheduled"
        return {"state": "none", "key": key, "reason": reason}

    def state(self) -> dict:
        k = self._current_key
        return {"on": self.on(), "available": self.available, "ffmpeg": bool(self.ffmpeg), "numpy": self.numpy,
                "key": k, "state": self._state.get(k, ""), "version": self.version,
                "queued": len(self._queue) + (1 if self._running else 0), "lastMs": self.last_ms, "error": self.error}

    def bump(self):
        self.version += 1
        try:
            self.on_change()
        except Exception as e:
            log.debug("analysis on_change: %s", e)

    # ---- running -------------------------------------------------------------

    async def _pump(self):
        while self._queue:
            job = self._queue.pop(0)
            await self._run(job)

    async def _run(self, job: Job):
        self._running = job
        job.started = time.monotonic()
        rc, data, err = None, {}, b""
        try:
            env = dict(os.environ, OPENBLAS_NUM_THREADS="1", OMP_NUM_THREADS="1", MKL_NUM_THREADS="1")
            # Never preexec_fn: the daemon runs threads (tidalapi), and the
            # worker lowers its own priority on Linux.
            job.proc = await asyncio.create_subprocess_exec(
                *self.worker_cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env,
                creationflags=(0x40 | subprocess.CREATE_NO_WINDOW) if WINDOWS else 0)
            if WINDOWS:
                from .system import tie_to_daemon
                tie_to_daemon(job.proc.pid)
            if job.cancelled:               # retargeted while it was starting
                self._kill(job)
            line = json.dumps({"source": job.source, "dash": job.dash, "duration": job.duration, "bpm": job.bpm,
                               "ffmpeg": self.ffmpeg, "maxSeconds": MAX_SECONDS}) + "\n"
            out, err = await asyncio.wait_for(job.proc.communicate(line.encode()),
                                              timeout=min(600, 90 + 2 * job.duration))
            rc = job.proc.returncode
            try:
                data = json.loads(out.decode("utf-8", "replace").strip().splitlines()[-1]) if out.strip() else {}
            except (ValueError, IndexError):
                data = {}
        except (asyncio.TimeoutError, asyncio.CancelledError) as e:
            self._kill(job)
            if isinstance(e, asyncio.CancelledError):
                job.cancelled = True
                raise
            data = {"error": "timeout"}
        except Exception as e:
            data = {"error": f"worker: {type(e).__name__}"}
        finally:
            ms = int((time.monotonic() - job.started) * 1000)
            self._running = None
            self._unlink(job)
            if job.cancelled:
                if not any(j.key == job.key for j in self._queue):   # else wanted again: it stays "pending"
                    self._forget(job)
                log.info("analysis %s: stopped after %d ms", job.key, ms)
            elif rc == 0 and isinstance(data, dict) and data.get("state") == "ready" and self._fits(job, data):
                data.update(v=MAP_V, key=job.key, id=job.track_id, provider=job.provider, at=time.time(), ms=ms)
                try:
                    await asyncio.to_thread(write_atomic, self._path(job.key),
                                            json.dumps(data, separators=(",", ":")).encode())
                    self._set(job.key, "ready")
                    self._failed.pop(job.key, None)
                    self.last_ms = ms
                except OSError as e:
                    self._fail(job, f"cache: {e.strerror or e}")
                log.info("analysis %s: ready in %d ms (%d drops)", job.key, ms, len(data.get("drops") or []))
            else:
                if rc == 0 and data.get("state") == "ready":
                    error = "duration mismatch"
                else:
                    tail = err.decode("utf-8", "replace").strip().splitlines()[-1:] if err else []
                    error = data.get("error") if isinstance(data, dict) and data.get("error") else (tail or ["worker failed"])[-1]
                self._fail(job, error)
                log.info("analysis %s: failed (rc %s, %d ms): %s", job.key, rc, ms, self.error)
            self.bump()

    @staticmethod
    def _fits(job: Job, data: dict) -> bool:
        try:
            return abs(float(data.get("duration") or 0) - job.duration) <= DUR_SLACK
        except (TypeError, ValueError):
            return False

    def _fail(self, job: Job, error: str):
        self.error = redact(str(error))[:200]
        self._failed[job.key] = (time.monotonic(), self.error, job.sig)
        self._set(job.key, "failed")

    def _kill(self, job: Job):
        job.cancelled = True
        p = job.proc
        if p is None or p.returncode is not None:
            return
        try:
            if WINDOWS:
                p.kill()                 # the worker's job object takes ffmpeg with it
            else:
                p.terminate()            # the worker's SIGTERM handler kills ffmpeg first

                async def later():
                    await asyncio.sleep(2)
                    if p.returncode is None:
                        p.kill()
                asyncio.get_running_loop().create_task(later())
        except (ProcessLookupError, OSError, RuntimeError):
            pass

    def _unlink(self, job: Job):
        if job.mpd_copy:
            try:
                job.mpd_copy.unlink(missing_ok=True)
            except OSError:
                pass

    async def close(self):
        self._queue.clear()
        if self._running:
            self._kill(self._running)
        if self._pump_task and not self._pump_task.done():
            self._pump_task.cancel()
            try:
                await self._pump_task
            except (asyncio.CancelledError, Exception):
                pass
        for f in self.tmp.glob("*.mpd"):
            try:
                f.unlink()
            except OSError:
                pass
