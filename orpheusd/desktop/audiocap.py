"""audiocap: Orpheus's own audio, as cava-style bars, on Windows.

cava's Windows build loopback-captures the whole default output, so the
visualizers dance to whatever else is playing: a game, Discord, a video. This
captures only orpheusd's process tree (so its mpv) through WASAPI process
loopback (Windows 10 2004 and later), and prints exactly what cava's raw ascii
output prints, so Service.qml reads it the same way:

    python -m orpheusd.desktop.audiocap [--fps 60] [--bars 32]

One line per frame, `bars` values in 0..1000 each followed by ';'. The target
comes from the daemon's /status (player.mpvPid and its parent) and is followed
across restarts. With nothing to capture it prints zero frames, so the caller
still sees a live stream. Exits 2 at once where process loopback is
unavailable, so the caller can fall back to cava.
"""
from __future__ import annotations

import argparse
import ctypes
import json
import os
import sys
import threading
import time
import urllib.request
from ctypes import wintypes

import numpy as np

RATE = 48000
CHANNELS = 2
FFT_N = 4096               # 85 ms at 48 kHz: ~12 Hz bins, enough for the 50 Hz bar
LOW_HZ, HIGH_HZ = 50.0, 10000.0   # cava's default cutoffs
PORT = int(os.environ.get("ORPHEUS_PORT", 47837))

# ---- COM plumbing (ctypes, no comtypes) ---------------------------------------

ole32 = ctypes.windll.ole32
kernel32 = ctypes.windll.kernel32
HRESULT = ctypes.c_long
S_OK, E_NOINTERFACE = 0, ctypes.c_long(0x80004002).value


class GUID(ctypes.Structure):
    _fields_ = [("d1", ctypes.c_ulong), ("d2", ctypes.c_ushort), ("d3", ctypes.c_ushort), ("d4", ctypes.c_ubyte * 8)]

    @classmethod
    def of(cls, s: str) -> "GUID":
        g = cls()
        ole32.CLSIDFromString(ctypes.c_wchar_p("{" + s + "}"), ctypes.byref(g))
        return g

    def __eq__(self, other):
        return bytes(self) == bytes(other)


IID_IUnknown = GUID.of("00000000-0000-0000-C000-000000000046")
IID_IAgileObject = GUID.of("94EA2B94-E9CC-49E0-C0FF-EE64CA8F5B90")
IID_Handler = GUID.of("41D949AB-9862-444A-80F6-C261334DA5EB")    # IActivateAudioInterfaceCompletionHandler
IID_IAudioClient = GUID.of("1CB9AD4C-DBFA-4C32-B178-C2F568A703B2")
IID_IAudioCaptureClient = GUID.of("C8ADBD64-E71E-48A0-A4DE-185C395CD317")

VT_BLOB = 65
AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK = 1
PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE = 0
AUDCLNT_SHAREMODE_SHARED = 0
AUDCLNT_STREAMFLAGS_LOOPBACK = 0x00020000
AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM = 0x80000000
AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY = 0x08000000
AUDCLNT_BUFFERFLAGS_SILENT = 0x2
WAVE_FORMAT_IEEE_FLOAT = 3


class ActivationParams(ctypes.Structure):          # AUDIOCLIENT_ACTIVATION_PARAMS
    _fields_ = [("ActivationType", ctypes.c_int), ("TargetProcessId", wintypes.DWORD), ("ProcessLoopbackMode", ctypes.c_int)]


class PropVariantBlob(ctypes.Structure):           # PROPVARIANT holding a VT_BLOB
    _fields_ = [("vt", ctypes.c_ushort), ("r1", ctypes.c_ushort), ("r2", ctypes.c_ushort), ("r3", ctypes.c_ushort),
                ("cbSize", ctypes.c_ulong), ("pBlobData", ctypes.c_void_p)]


class WaveFormatEx(ctypes.Structure):
    _fields_ = [("wFormatTag", ctypes.c_ushort), ("nChannels", ctypes.c_ushort), ("nSamplesPerSec", ctypes.c_ulong),
                ("nAvgBytesPerSec", ctypes.c_ulong), ("nBlockAlign", ctypes.c_ushort), ("wBitsPerSample", ctypes.c_ushort),
                ("cbSize", ctypes.c_ushort)]


_protos: dict = {}


def com_call(obj, index: int, *args, argtypes=()):
    """Call vtable slot `index` on a COM pointer; returns the HRESULT."""
    proto = _protos.get(argtypes)
    if proto is None:
        proto = _protos[argtypes] = ctypes.WINFUNCTYPE(HRESULT, ctypes.c_void_p, *argtypes)
    vtbl = ctypes.cast(obj, ctypes.POINTER(ctypes.POINTER(ctypes.c_void_p)))[0]
    return proto(vtbl[index])(obj, *args)


def release(obj):
    if obj:
        com_call(obj, 2)


class CaptureError(Exception):
    def __init__(self, what: str, hr: int):
        super().__init__(f"{what} failed: 0x{hr & 0xFFFFFFFF:08X}")
        self.hr = hr


def check(what: str, hr: int):
    if hr < 0:
        raise CaptureError(what, hr)


# The completion handler: a static COM object with IUnknown, IAgileObject and
# ActivateCompleted. WASAPI calls it once, on one of its own threads.
_QI = ctypes.WINFUNCTYPE(HRESULT, ctypes.c_void_p, ctypes.POINTER(GUID), ctypes.POINTER(ctypes.c_void_p))
_REF = ctypes.WINFUNCTYPE(ctypes.c_ulong, ctypes.c_void_p)
_DONE = ctypes.WINFUNCTYPE(HRESULT, ctypes.c_void_p, ctypes.c_void_p)


class _HandlerVtbl(ctypes.Structure):
    _fields_ = [("QueryInterface", _QI), ("AddRef", _REF), ("Release", _REF), ("ActivateCompleted", _DONE)]


class _HandlerObj(ctypes.Structure):
    _fields_ = [("lpVtbl", ctypes.POINTER(_HandlerVtbl))]


class CompletionHandler:
    def __init__(self):
        self.done = threading.Event()
        self.hr = 0
        self.client = None          # IAudioClient*, owned by whoever takes it
        self._vtbl = _HandlerVtbl(_QI(self._qi), _REF(lambda this: 1), _REF(lambda this: 1), _DONE(self._completed))
        self._obj = _HandlerObj(ctypes.pointer(self._vtbl))
        self.ptr = ctypes.cast(ctypes.pointer(self._obj), ctypes.c_void_p)

    def _qi(self, this, riid, ppv):
        if riid[0] in (IID_IUnknown, IID_Handler, IID_IAgileObject):
            ppv[0] = this
            return S_OK
        ppv[0] = None
        return E_NOINTERFACE

    def _completed(self, this, op):
        try:
            hr = HRESULT()
            unk = ctypes.c_void_p()
            # IActivateAudioInterfaceAsyncOperation::GetActivateResult
            got = com_call(op, 3, ctypes.byref(hr), ctypes.byref(unk),
                           argtypes=(ctypes.POINTER(HRESULT), ctypes.POINTER(ctypes.c_void_p)))
            self.hr = got if got < 0 else hr.value
            if self.hr >= 0 and unk:
                self.client = unk.value
        finally:
            self.done.set()
        return S_OK


class ProcessCapture:
    """Process-loopback capture of `pid` and its children, as mono float32."""

    def __init__(self, pid: int):
        self.pid = pid
        self.client = self.capture = None
        params = ActivationParams(AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK, pid,
                                  PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE)
        pv = PropVariantBlob(vt=VT_BLOB, cbSize=ctypes.sizeof(params),
                             pBlobData=ctypes.cast(ctypes.pointer(params), ctypes.c_void_p))
        handler = CompletionHandler()
        op = ctypes.c_void_p()
        activate = ctypes.windll.mmdevapi.ActivateAudioInterfaceAsync
        activate.restype = HRESULT
        activate.argtypes = [ctypes.c_wchar_p, ctypes.POINTER(GUID), ctypes.c_void_p, ctypes.c_void_p,
                             ctypes.POINTER(ctypes.c_void_p)]
        check("ActivateAudioInterfaceAsync",
              activate("VAD\\Process_Loopback", ctypes.byref(IID_IAudioClient), ctypes.byref(pv), handler.ptr,
                       ctypes.byref(op)))
        try:
            if not handler.done.wait(5):
                raise CaptureError("activation timed out", -1)
            check("activation", handler.hr)
            self.client = handler.client
        finally:
            release(op.value)
        # Process loopback has no mix format of its own (GetMixFormat is E_NOTIMPL):
        # ask for float stereo at 48 kHz and let the engine convert. Float, not
        # 16-bit: mpv's volume is applied before we hear it, and at a low volume
        # 16 bits leave the music a few LSBs of quantisation noise.
        fmt = WaveFormatEx(WAVE_FORMAT_IEEE_FLOAT, CHANNELS, RATE, RATE * CHANNELS * 4, CHANNELS * 4, 32, 0)
        flags = AUDCLNT_STREAMFLAGS_LOOPBACK | AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY
        check("IAudioClient::Initialize",
              com_call(self.client, 3, AUDCLNT_SHAREMODE_SHARED, flags, ctypes.c_longlong(2_000_000), ctypes.c_longlong(0),
                       ctypes.byref(fmt), None,
                       argtypes=(ctypes.c_int, wintypes.DWORD, ctypes.c_longlong, ctypes.c_longlong,
                                 ctypes.POINTER(WaveFormatEx), ctypes.c_void_p)))
        cap = ctypes.c_void_p()
        check("IAudioClient::GetService",
              com_call(self.client, 14, ctypes.byref(IID_IAudioCaptureClient), ctypes.byref(cap),
                       argtypes=(ctypes.POINTER(GUID), ctypes.POINTER(ctypes.c_void_p))))
        self.capture = cap.value
        check("IAudioClient::Start", com_call(self.client, 10))

    def read(self) -> np.ndarray | None:
        """Everything captured since the last call, mono float32 in -1..1;
        None when no packet arrived at all."""
        chunks = []
        size = ctypes.c_uint32()
        data = ctypes.c_void_p()
        frames = ctypes.c_uint32()
        flags = wintypes.DWORD()
        while True:
            check("GetNextPacketSize", com_call(self.capture, 5, ctypes.byref(size), argtypes=(ctypes.POINTER(ctypes.c_uint32),)))
            if size.value == 0:
                break
            check("GetBuffer", com_call(self.capture, 3, ctypes.byref(data), ctypes.byref(frames), ctypes.byref(flags), None, None,
                                        argtypes=(ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(ctypes.c_uint32),
                                                  ctypes.POINTER(wintypes.DWORD), ctypes.c_void_p, ctypes.c_void_p)))
            n = frames.value
            if flags.value & AUDCLNT_BUFFERFLAGS_SILENT or not data.value:
                chunks.append(np.zeros(n, np.float32))
            else:
                raw = np.ctypeslib.as_array(ctypes.cast(data, ctypes.POINTER(ctypes.c_float)), (n * CHANNELS,))
                chunks.append(raw.reshape(n, CHANNELS).mean(axis=1))   # mean() copies out of the buffer
            com_call(self.capture, 4, n, argtypes=(ctypes.c_uint32,))
        return np.concatenate(chunks) if chunks else None

    def close(self):
        if self.client:
            com_call(self.client, 11)       # Stop
        release(self.capture)
        release(self.client)
        self.client = self.capture = None


# ---- finding mpv --------------------------------------------------------------

SYNCHRONIZE = 0x00100000
PROCESS_QUERY_LIMITED_INFORMATION = 0x1000


def daemon_mpv_pid() -> int:
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{PORT}/status", timeout=2) as r:
            return int((json.load(r).get("player") or {}).get("mpvPid") or 0)
    except Exception:
        return 0


class _ProcEntry(ctypes.Structure):                 # PROCESSENTRY32W
    _fields_ = [("dwSize", wintypes.DWORD), ("cntUsage", wintypes.DWORD), ("th32ProcessID", wintypes.DWORD),
                ("th32DefaultHeapID", ctypes.c_size_t), ("th32ModuleID", wintypes.DWORD), ("cntThreads", wintypes.DWORD),
                ("th32ParentProcessID", wintypes.DWORD), ("pcPriClassBase", ctypes.c_long), ("dwFlags", wintypes.DWORD),
                ("szExeFile", ctypes.c_wchar * 260)]


def _processes() -> dict[int, tuple[int, str]]:
    """pid -> (parent pid, exe name)."""
    out = {}
    kernel32.CreateToolhelp32Snapshot.restype = ctypes.c_void_p
    snap = kernel32.CreateToolhelp32Snapshot(0x2, 0)       # TH32CS_SNAPPROCESS
    if not snap or snap == ctypes.c_void_p(-1).value:
        return out
    try:
        e = _ProcEntry(dwSize=ctypes.sizeof(_ProcEntry))
        ok = kernel32.Process32FirstW(ctypes.c_void_p(snap), ctypes.byref(e))
        while ok:
            out[e.th32ProcessID] = (e.th32ParentProcessID, e.szExeFile.lower())
            ok = kernel32.Process32NextW(ctypes.c_void_p(snap), ctypes.byref(e))
    finally:
        kernel32.CloseHandle(ctypes.c_void_p(snap))
    return out


def daemon_target() -> int:
    """The process tree to capture: orpheusd itself, mpv's parent, so that a
    recycled mpv, or a second one the daemon starts for a crossfade, is in it
    from its first sample (process loopback includes children started later).
    Plain mpv if the parent cannot be told apart from a reused pid."""
    mpv = daemon_mpv_pid()
    if not mpv:
        return 0
    procs = _processes()
    parent = procs.get(mpv, (0, ""))[0]
    name = procs.get(parent, (0, ""))[1] if parent else ""
    return parent if name.startswith("python") else mpv


class Alive:
    """A handle on the target, to notice it exit without asking the daemon."""

    def __init__(self, pid: int):
        self.h = kernel32.OpenProcess(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION, False, pid)

    def __bool__(self):
        return bool(self.h) and kernel32.WaitForSingleObject(self.h, 0) != 0   # WAIT_OBJECT_0: exited

    def close(self):
        if self.h:
            kernel32.CloseHandle(self.h)
            self.h = None


# ---- the bars -------------------------------------------------------------------

class Bars:
    """FFT -> log bands -> cava's gravity, integral smoothing and autosens."""

    def __init__(self, bars: int, fps: int, noise_reduction: float):
        self.n, self.fps = bars, fps
        self.window = np.hanning(FFT_N).astype(np.float32)
        freqs = np.fft.rfftfreq(FFT_N, 1 / RATE)
        edges_hz = LOW_HZ * (HIGH_HZ / LOW_HZ) ** (np.arange(bars + 1) / bars)
        edges = np.searchsorted(freqs, edges_hz)
        for i in range(1, len(edges)):              # every bar gets at least one bin
            edges[i] = max(edges[i], edges[i - 1] + 1)
        self.lo, self.hi = edges[:-1], edges[1:]
        centre = np.sqrt(edges_hz[:-1] * edges_hz[1:])
        # Lift the treble against music's downward tilt, so the high bars move as
        # well as the bass ones; autosens sets the overall gain. cava weights by
        # frequency over several FFT sizes; with one FFT, f^0.75 lands on the same
        # bar profile (checked side by side on pink noise).
        w = centre ** 0.75
        self.eq = (w / w.mean()).astype(np.float32)
        self.counts = (self.hi - self.lo).astype(np.float32)
        nr = max(0.0, min(1.0, noise_reduction / 100))
        self.nr = nr
        frame_mod = 66 / fps
        self.integral = nr ** frame_mod if nr > 0 else 0.0
        self.gravity_mod = max(1.0, (60 / fps) ** 2.5 * 1.54 / max(nr, 0.01))
        self.fall_step = 0.028 * (60 / fps) ** 0.5
        self.sens = 1.0
        self.sens_init = True
        self.prev = np.zeros(bars, np.float32)
        self.peak = np.zeros(bars, np.float32)
        self.fall = np.zeros(bars, np.float32)
        self.mem = np.zeros(bars, np.float32)
        self.rate_mod = 60 / fps                  # autosens steps are per 60 Hz frame

    def frame(self, samples: np.ndarray, silent: bool) -> np.ndarray:
        spec = np.abs(np.fft.rfft(samples * self.window)).astype(np.float32)
        csum = np.concatenate(([0.0], np.cumsum(spec, dtype=np.float64))).astype(np.float32)
        out = (csum[self.hi] - csum[self.lo]) / self.counts * self.eq / FFT_N * self.sens

        # gravity: a falling bar drops along a parabola from its last peak
        falling = (out < self.prev) & (self.nr > 0.1)
        dropped = np.maximum(0, self.peak * (1 - self.fall * self.fall * self.gravity_mod))
        out = np.where(falling, dropped, out)
        self.fall = np.where(falling, self.fall + self.fall_step, 0)
        self.peak = np.where(falling, self.peak, out)
        self.prev = out
        # integral: each frame carries the last one forward
        out = self.mem * self.integral + out
        self.mem = out

        if (out > 1).any():
            self.sens *= 0.98 ** self.rate_mod
            self.sens_init = False
        elif not silent:
            self.sens *= (1.1 if self.sens_init else 1.001) ** self.rate_mod
        return np.clip(out, 0, 1)


def emit(values: np.ndarray):
    line = ";".join(str(v) for v in values.tolist()) + ";\n"
    os.write(1, line.encode())


# ---- main loop -------------------------------------------------------------------

def run(fps: int, bars: int, noise_reduction: float, pid_override: int, seconds: float):
    hop = RATE // fps
    shaper = Bars(bars, fps, noise_reduction)
    ring = np.zeros(FFT_N, np.float32)
    zero_line = np.zeros(bars, np.int64)
    cap: ProcessCapture | None = None
    alive: Alive | None = None
    last_audio = 0.0
    next_lookup = 0.0
    period = 1 / fps
    start = time.perf_counter()
    deadline = start
    winmm = ctypes.windll.winmm
    winmm.timeBeginPeriod(1)            # Sleep() to the millisecond, so the frame clock holds
    try:
        while not seconds or time.perf_counter() - start < seconds:
            now = time.perf_counter()
            # (Re)target: mpv appears late, exits, or the daemon recycles it.
            if cap is not None and not alive:
                cap.close(); alive.close()
                cap = alive = None
                next_lookup = 0
            if cap is None and now >= next_lookup:
                pid = pid_override or daemon_target()
                probe = Alive(pid) if pid else None
                if probe:           # activation would accept a dead pid and hear nothing
                    try:
                        cap, alive = ProcessCapture(pid), probe
                        print(f"audiocap: listening to pid {pid}", file=sys.stderr, flush=True)
                    except CaptureError as e:
                        print(f"audiocap: pid {pid}: {e}", file=sys.stderr, flush=True)
                        probe.close()
                elif probe is not None:
                    probe.close()
                # A dead pid the daemon has yet to replace: ask again soon, not every frame.
                next_lookup = now + (1.0 if cap or not pid else 0.25)
            elif cap is not None and not pid_override and now >= next_lookup:
                # Belt and braces: a target change the handle missed (the
                # parent check fell back to mpv's pid, and mpv was replaced
                # before the old one exited).
                pid = daemon_target()
                if pid and pid != cap.pid:
                    cap.close(); alive.close()
                    cap = alive = None
                    continue
                next_lookup = now + 10.0

            got = None
            if cap is not None:
                try:
                    got = cap.read()
                except CaptureError as e:
                    print(f"audiocap: {e}; reconnecting", file=sys.stderr, flush=True)
                    cap.close(); alive.close()
                    cap = alive = None
            if got is not None and len(got):
                last_audio = now
                ring = np.concatenate((ring, got))[-FFT_N:]
            elif now - last_audio > 0.1:
                # Nothing for a while: mpv paused or gone. Feed silence so the bars fall.
                ring = np.concatenate((ring, np.zeros(hop, np.float32)))[-FFT_N:]

            silent = not ring.any()
            if silent and not shaper.mem.any() and not shaper.prev.any():
                emit(zero_line)
            else:
                emit((shaper.frame(ring, silent) * 1000).astype(np.int64))

            deadline += period
            delay = deadline - time.perf_counter()
            if delay > 0:
                time.sleep(delay)
            elif delay < -0.25:
                deadline = time.perf_counter()   # fell far behind (sleep/suspend): don't burst
    finally:
        winmm.timeEndPeriod(1)
        if cap:
            cap.close()


def supported() -> bool:
    """Process loopback works here: activate it once against ourselves."""
    try:
        ProcessCapture(os.getpid()).close()
        return True
    except (CaptureError, AttributeError, OSError) as e:
        print(f"audiocap: process loopback unavailable: {e}", file=sys.stderr, flush=True)
        return False


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--fps", type=int, default=60)
    ap.add_argument("--bars", type=int, default=32)
    ap.add_argument("--noise-reduction", type=float, default=70, help="cava's noise_reduction, 0..100")
    ap.add_argument("--pid", type=int, default=0, help="capture this process tree instead of the daemon's mpv")
    ap.add_argument("--seconds", type=float, default=0, help="stop after this long (testing)")
    args = ap.parse_args()
    if sys.platform != "win32":
        sys.exit(2)
    ole32.CoInitializeEx(None, 0)           # COINIT_MULTITHREADED: the handler is agile
    if not supported():                     # e.g. before Windows 10 2004: let the caller use cava
        sys.exit(2)
    try:
        run(max(10, min(240, args.fps)), max(1, min(256, args.bars)), args.noise_reduction, args.pid, args.seconds)
    except (BrokenPipeError, OSError) as e:
        if getattr(e, "errno", None) in (22, 32) or isinstance(e, BrokenPipeError):
            return                              # the reader went away
        raise
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
