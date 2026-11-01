"""Hang recorder: when the GUI thread stops beating, leave evidence.

A QTimer on the GUI thread stamps time.monotonic() every 250 ms; a plain
daemon thread (no Qt, no Qt message handler) looks at the stamp every 500 ms.
Stale for 4 s: every thread's Python stack goes to state/hang-<ts>.txt, a
minidump of this process to state/hang-<ts>.dmp (Windows), and a line to the
log. Newest 5 hang-* pairs are kept. The watchdog never raises.
"""
from __future__ import annotations

import faulthandler
import sys
import threading
import time
from pathlib import Path

BEAT_MS = 250
CHECK_S = 0.5
STALL_S = 4.0
KEEP = 5

# MiniDumpWithIndirectlyReferencedMemory | MiniDumpScanMemory | MiniDumpWithThreadInfo
_DUMP_TYPE = 0x00000040 | 0x00000010 | 0x00001000


def write_minidump(path: Path) -> bool:
    """MiniDumpWriteDump on our own process, from the calling thread."""
    if sys.platform != "win32":
        return False
    import ctypes
    from ctypes import wintypes
    k32 = ctypes.WinDLL("kernel32", use_last_error=True)
    dbg = ctypes.WinDLL("dbghelp", use_last_error=True)
    k32.GetCurrentProcess.restype = wintypes.HANDLE
    k32.GetCurrentProcessId.restype = wintypes.DWORD
    k32.CreateFileW.restype = wintypes.HANDLE
    k32.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, wintypes.LPVOID,
                                wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE]
    k32.CloseHandle.argtypes = [wintypes.HANDLE]
    dbg.MiniDumpWriteDump.argtypes = [wintypes.HANDLE, wintypes.DWORD, wintypes.HANDLE, wintypes.DWORD,
                                      wintypes.LPVOID, wintypes.LPVOID, wintypes.LPVOID]
    dbg.MiniDumpWriteDump.restype = wintypes.BOOL
    h = k32.CreateFileW(str(path), 0x40000000, 0, None, 2, 0x80, None)   # GENERIC_WRITE, CREATE_ALWAYS
    if h in (None, wintypes.HANDLE(-1).value):
        return False
    try:
        return bool(dbg.MiniDumpWriteDump(k32.GetCurrentProcess(), k32.GetCurrentProcessId(), h,
                                          _DUMP_TYPE, None, None, None))
    finally:
        k32.CloseHandle(h)


def prune(state: Path, keep: int = KEEP):
    stamps = sorted({p.stem for p in state.glob("hang-*.*") if p.suffix in (".txt", ".dmp")}, reverse=True)
    for stem in stamps[keep:]:
        for ext in (".txt", ".dmp"):
            try:
                (state / (stem + ext)).unlink()
            except OSError:
                pass


class HangRecorder:
    def __init__(self, state_dir: Path, say, stall_s: float = STALL_S):
        self.state = Path(state_dir)
        self.say = say
        self.stall_s = stall_s
        self.beat = time.monotonic()
        self._timer = None
        self._thread = None

    def start(self, parent=None):
        from PySide6.QtCore import QTimer
        self._timer = QTimer(parent)
        self._timer.timeout.connect(self._tick)
        self._timer.start(BEAT_MS)
        self.beat = time.monotonic()
        self._thread = threading.Thread(target=self._watch, name="hang-watchdog", daemon=True)
        self._thread.start()
        return self

    def _tick(self):
        self.beat = time.monotonic()

    def _watch(self):
        stalled_at = None        # monotonic time of the beat we reported
        while True:
            try:
                time.sleep(CHECK_S)
                age = time.monotonic() - self.beat
                if stalled_at is None:
                    if age >= self.stall_s:
                        stalled_at = self.beat
                        self._record(age)
                elif self.beat != stalled_at:
                    self.say(f"hang: GUI thread back after {time.monotonic() - stalled_at:.0f}s")
                    stalled_at = None
            except Exception:
                try:
                    time.sleep(CHECK_S)
                except Exception:
                    pass

    def _record(self, age: float):
        ts = time.strftime("%Y%m%d-%H%M%S")
        txt, dmp = self.state / f"hang-{ts}.txt", self.state / f"hang-{ts}.dmp"
        wrote = []
        try:
            self.state.mkdir(parents=True, exist_ok=True)
            with open(txt, "w", encoding="utf-8") as f:
                f.write(f"GUI thread stalled {age:.1f}s at {time.strftime('%Y-%m-%d %H:%M:%S')}\n"
                        f"pid {__import__('os').getpid()}  python {sys.version.split()[0]}\n\n")
                f.flush()
                faulthandler.dump_traceback(file=f, all_threads=True)
            wrote.append(txt.name)
        except Exception as e:
            self.say(f"hang: traceback failed: {e}")
        try:
            if write_minidump(dmp):
                wrote.append(dmp.name)
        except Exception as e:
            self.say(f"hang: minidump failed: {e}")
        try:
            prune(self.state)
        except Exception:
            pass
        self.say(f"hang: GUI thread stalled {age:.0f}s, wrote hang-{ts}.* ({', '.join(wrote) or 'nothing'})")
