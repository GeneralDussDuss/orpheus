"""Discord Rich Presence: "Listening to <title> by <artist>" on the user's profile.

Speaks Discord's local IPC directly (no SDK, no dependency): a named pipe
\\\\.\\pipe\\discord-ipc-0 .. 9, where each frame is an 8-byte little-endian header
(opcode, payload length) and a JSON payload. A connection starts with a HANDSHAKE
(op 0, {"v": 1, "client_id": ...}) answered by a READY dispatch; then each
SET_ACTIVITY is an op 1 FRAME, answered by one frame of its own.

It needs a Discord application of the user's own, because Discord shows that
application's name ("Listening to Orpheus"):

  1. https://discord.com/developers/applications -> New Application, name it "Orpheus".
  2. Copy its Application ID into ~/.config/orpheus/config.json:
         "discordClientId": "123456789012345678"
     Empty or missing means Rich Presence is off.
  3. Optional: Rich Presence -> Art Assets, upload Orpheus's icon under the key
     "orpheus" (python -m orpheusd.desktop --write-icon orpheus.png). It shows as
     the small badge; without it Discord just leaves the badge out.

The cover is the track's own https URL; Discord proxies external image URLs.
It clears when playback pauses or stops, reconnects when Discord restarts, and
everything runs on its own thread, so a hung Discord never stalls the app.
"""
from __future__ import annotations

import json
import os
import struct
import sys
import threading
import time
import uuid
from pathlib import Path

OP_HANDSHAKE, OP_FRAME, OP_CLOSE, OP_PING, OP_PONG = 0, 1, 2, 3, 4
PIPE = r"\\.\pipe\discord-ipc-"
CONFIG = Path(os.environ.get("ORPHEUS_HOME") or Path.home()) / ".config" / "orpheus" / "config.json"
RETRY_S = 15                  # between connection attempts while there is something to show
MIN_GAP_S = 4.5               # Discord allows 5 SET_ACTIVITY per 20 s


def log(*a):
    print("orpheus-desktop: discord:", *a, file=sys.stderr)


def client_id(cfg: dict | None = None) -> str:
    if cfg is None:
        try:
            cfg = json.loads(CONFIG.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            cfg = {}
    v = cfg.get("discordClientId", "") if isinstance(cfg, dict) else ""
    v = str(v or "").strip()
    return v if v.isdigit() else ""


# ---- framing -----------------------------------------------------------------------

def pack(op: int, payload: dict) -> bytes:
    data = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    return struct.pack("<II", op, len(data)) + data


def unpack_header(head: bytes) -> tuple[int, int]:
    return struct.unpack("<II", head)


class Pipe:
    """One connection to a Discord IPC pipe. Reads time out (PeekNamedPipe), so a
    Discord that stops answering cannot hang the thread."""

    def __init__(self, path: str):
        self.path = path
        self.f = open(path, "r+b", buffering=0)
        self._peek = None
        if sys.platform == "win32":
            import ctypes
            import msvcrt
            from ctypes import wintypes
            k = ctypes.windll.kernel32
            k.PeekNamedPipe.argtypes = [wintypes.HANDLE, ctypes.c_void_p, wintypes.DWORD, ctypes.c_void_p,
                                        ctypes.POINTER(wintypes.DWORD), ctypes.c_void_p]
            handle = msvcrt.get_osfhandle(self.f.fileno())

            def avail() -> int:
                n = wintypes.DWORD()
                if not k.PeekNamedPipe(handle, None, 0, None, ctypes.byref(n), None):
                    raise OSError("pipe closed")
                return n.value
            self._peek = avail

    def send(self, op: int, payload: dict):
        self.f.write(pack(op, payload))

    def _read(self, n: int, deadline: float) -> bytes:
        out = b""
        while len(out) < n:
            if self._peek is not None:
                while self._peek() == 0:
                    if time.monotonic() > deadline:
                        raise TimeoutError("discord did not answer")
                    time.sleep(0.02)
            chunk = self.f.read(n - len(out))
            if not chunk:
                raise OSError("pipe closed")
            out += chunk
        return out

    def recv(self, timeout: float = 5.0) -> tuple[int, dict]:
        deadline = time.monotonic() + timeout
        op, length = unpack_header(self._read(8, deadline))
        if length > 1 << 20:
            raise OSError(f"frame too large ({length})")
        body = self._read(length, deadline) if length else b"{}"
        try:
            return op, json.loads(body.decode("utf-8"))
        except ValueError:
            return op, {}

    def alive(self) -> bool:
        """False once Discord has gone (the pipe breaks). Throws away anything
        unsolicited it sent, so the next answer read is the one asked for."""
        if self._peek is None:
            return not self.f.closed
        try:
            while self._peek() >= 8:
                self.recv(1.0)
            return True
        except (OSError, TimeoutError):
            return False

    def close(self):
        try:
            self.f.close()
        except OSError:
            pass


class HandshakeError(Exception):
    pass


def connect(cid: str, prefix: str = PIPE, timeout: float = 5.0) -> tuple[Pipe, dict]:
    """Find a Discord pipe and say hello. Returns the pipe and the READY payload;
    raises OSError when no Discord is listening, HandshakeError when one refuses."""
    last: Exception = OSError("no discord-ipc pipe")
    for i in range(10):
        try:
            p = Pipe(f"{prefix}{i}")
        except OSError as e:
            last = e
            continue
        try:
            p.send(OP_HANDSHAKE, {"v": 1, "client_id": cid})
            op, msg = p.recv(timeout)
        except (OSError, TimeoutError) as e:
            p.close()
            last = e
            continue
        if op == OP_FRAME and msg.get("evt") == "READY":
            return p, msg
        p.close()
        raise HandshakeError(f"{msg.get('code', op)}: {msg.get('message', msg)}")
    raise last if isinstance(last, OSError) else OSError(str(last))


# ---- what to show ------------------------------------------------------------------

def _text(s, fallback: str = "") -> str:
    s = str(s or fallback).strip()
    if len(s) == 1:
        s += " "          # Discord wants at least two characters
    return s[:128]


def activity(p: dict, now: float | None = None) -> dict | None:
    """The activity for a /status player dict, or None to clear it."""
    t = (p or {}).get("track") or {}
    if not t or not p.get("playing"):
        return None
    now = time.time() if now is None else now
    artists = t.get("artists") or ""
    artist = ", ".join(artists) if isinstance(artists, list) else str(artists)
    act = {"type": 2,                                          # Listening to
           "details": _text(t.get("title"), "Unknown track"),
           "state": _text(artist, "Unknown artist"),
           "assets": {"small_image": "orpheus", "small_text": "Orpheus"},
           "instance": False}
    album = _text(t.get("album"))
    art = str(t.get("art") or "")
    if art.startswith("https://") and len(art) <= 256:
        act["assets"]["large_image"] = art
        if album:
            act["assets"]["large_text"] = album
    duration = float(p.get("duration") or 0)
    position = float(p.get("position") or 0)
    if duration > 0:
        start = now - position
        act["timestamps"] = {"start": int(start * 1000), "end": int((start + duration) * 1000)}
    return act


def _same(a: dict | None, b: dict | None) -> bool:
    """Equal apart from timestamps drifting by under 3 s (the 1 s status poll)."""
    if a is None or b is None:
        return a is b
    if {k: v for k, v in a.items() if k != "timestamps"} != {k: v for k, v in b.items() if k != "timestamps"}:
        return False
    ta, tb = a.get("timestamps") or {}, b.get("timestamps") or {}
    if bool(ta) != bool(tb):
        return False
    return not ta or abs(ta["start"] - tb["start"]) < 3000


class Presence:
    """Feed it /status player dicts with sync(); it keeps Discord in step."""

    def __init__(self, prefix: str = PIPE, cid=client_id):
        self.prefix = prefix
        self.cid = cid if callable(cid) else (lambda: cid)
        self.want: dict | None = None
        self.sent: dict | None = "unset"       # type: ignore[assignment]  # nothing sent yet
        self.pipe: Pipe | None = None
        self.pipe_cid = ""
        self.last_error = ""
        self.retry_at = 0.0
        self.last_send = 0.0
        self.extra_ok = True                    # status_display_type, until Discord says no
        self._wake = threading.Event()
        self._stop = False
        self._thread = threading.Thread(target=self._run, name="discord-presence", daemon=True)
        self._thread.start()

    def sync(self, p: dict):
        want = activity(p)
        if not _same(want, self.want):
            self.want = want
            self._wake.set()

    def stop(self):
        self._stop = True
        self._wake.set()
        self._thread.join(2)
        self._drop()

    # ---- the worker ----
    def _drop(self):
        if self.pipe:
            self.pipe.close()
        self.pipe, self.sent = None, "unset"     # type: ignore[assignment]

    def _run(self):
        while not self._stop:
            self._wake.wait(RETRY_S)
            self._wake.clear()
            if self._stop:
                break
            try:
                self._step()
            except Exception as e:          # never let the thread die
                self.last_error = repr(e)
                log("unexpected:", e)
                self._drop()

    def _step(self):
        cid = self.cid()
        if not cid:
            if self.pipe:                   # switched off in config: clear and let go
                self._send_activity(None)
                self._drop()
            return
        if self.pipe and (self.pipe_cid != cid or not self.pipe.alive()):
            if self.pipe_cid == cid:
                log("Discord went away; will reconnect")
            self._drop()
        want = self.want
        if self.pipe is None:
            if want is None or time.monotonic() < self.retry_at:
                if want is not None:
                    self._wake_later(self.retry_at - time.monotonic())
                return
            try:
                self.pipe, _ = connect(cid, self.prefix)
                self.pipe_cid, self.last_error = cid, ""
                log("connected")
            except HandshakeError as e:
                self.last_error = str(e)
                log("Discord refused the client id:", e)
                self.retry_at = time.monotonic() + RETRY_S * 8
                return
            except (OSError, TimeoutError) as e:
                self.last_error = str(e)        # Discord is not running; try again later
                self.retry_at = time.monotonic() + RETRY_S
                return
        if self.sent != "unset" and _same(want, self.sent):
            return
        gap = self.last_send + MIN_GAP_S - time.monotonic()
        if gap > 0:
            self._wake_later(gap)
            return
        try:
            self._send_activity(want)
        except (OSError, TimeoutError) as e:
            log("lost Discord:", e)
            self.last_error = str(e)
            self._drop()
            self.retry_at = time.monotonic() + 2
            self._wake_later(2.5)

    def _wake_later(self, s: float):
        threading.Timer(max(0.05, s), self._wake.set).start()

    def _send_activity(self, act: dict | None):
        assert self.pipe
        args: dict = {"pid": os.getpid()}
        if act is not None:
            act = dict(act)
            if self.extra_ok:
                act["status_display_type"] = 1        # the member list reads "Listening to <artist>"
            args["activity"] = act
        self.last_send = time.monotonic()
        self.pipe.send(OP_FRAME, {"cmd": "SET_ACTIVITY", "args": args, "nonce": uuid.uuid4().hex})
        op, msg = self.pipe.recv()
        if op == OP_CLOSE:
            raise OSError(f"closed: {msg.get('message', msg)}")
        if msg.get("evt") == "ERROR":
            if self.extra_ok and act is not None:
                self.extra_ok = False                 # an older client: try once without it
                self.last_send = 0
                self._send_activity({k: v for k, v in act.items() if k != "status_display_type"})
                return
            self.last_error = str((msg.get("data") or {}).get("message", msg))
            log("SET_ACTIVITY refused:", self.last_error)
        self.sent = {k: v for k, v in act.items() if k != "status_display_type"} if act else None


PRESENCE: list = []


def install() -> Presence:
    from .shims import PLAYER_LISTENERS
    p = Presence()
    PRESENCE[:] = [p]
    PLAYER_LISTENERS.append(p.sync)
    return p
