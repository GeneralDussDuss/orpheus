"""desktop.log: what the desktop app says, time-stamped, size-capped and kept
for one run back.

Under pythonw there is no stderr at all, so Qt's own warnings (and the QML's
console.warn) went nowhere. The log is put on file descriptor 2 itself: Qt's
default message handler then writes there from C, on whatever thread it is
on, with no Python involved. (A Python qInstallMessageHandler deadlocked: a
render thread warning while the GUI thread held the GIL waiting on it.)"""
from __future__ import annotations

import io
import os
import sys
import time
from pathlib import Path

# Qt's format for its own lines in the same file (set before QApplication).
QT_PATTERN = "%{time hh:mm:ss} qt %{if-warning}warning%{endif}%{if-critical}critical%{endif}" \
             "%{if-fatal}fatal%{endif}%{if-info}info%{endif}%{if-debug}debug%{endif}: %{message}"


def prepare_qt_env():
    """Before QApplication: make Qt write to stderr (it otherwise prefers
    OutputDebugString on Windows when there is no console) in our format."""
    os.environ.setdefault("QT_FORCE_STDERR_LOGGING", "1")
    os.environ.setdefault("QT_MESSAGE_PATTERN", QT_PATTERN)


class CappedLog(io.TextIOBase):
    """A text stream over a raw, append-mode file descriptor.

    With `fd=2` the file becomes the process's stderr, shared with Qt. The
    previous run's log is kept as `<name>.1` when this one opens (after a crash
    that is the one worth reading); past `limit` bytes the current file rolls
    over to `.1` too. Python's lines start with the time of day."""

    def __init__(self, path: Path, limit: int = 1 << 20, clock=time.localtime, fd: int | None = None):
        self.path = Path(path)
        self.limit = limit
        self.clock = clock
        self.target = fd          # 2 for stderr; None: a descriptor of our own
        self.fd = -1
        self._bol = True
        self._roll()

    def _point(self, fd: int):
        if self.target is None:
            self.fd = fd
            return
        os.dup2(fd, self.target)
        os.close(fd)
        self.fd = self.target
        if sys.platform == "win32":
            import ctypes
            import msvcrt
            # Native code that asks Windows rather than the C runtime for stderr.
            ctypes.windll.kernel32.SetStdHandle(-12, msvcrt.get_osfhandle(self.target))

    def _roll(self):
        if self.fd >= 0:
            if self.target is None:
                os.close(self.fd)
            else:   # let go of the file so it can be renamed; Qt writes nowhere meanwhile
                self._point(os.open(os.devnull, os.O_WRONLY))
            self.fd = -1 if self.target is None else self.fd
        old = self.path.with_name(self.path.name + ".1")
        try:
            if self.path.exists() and self.path.stat().st_size:
                os.replace(self.path, old)
        except OSError:
            pass                       # still open elsewhere: just start over
        flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_APPEND | getattr(os, "O_BINARY", 0)
        self._point(os.open(self.path, flags, 0o644))

    def write(self, s: str) -> int:
        if not s:
            return 0
        try:
            if os.fstat(self.fd).st_size > self.limit:
                self._roll()
        except OSError:
            pass
        stamp = time.strftime("%H:%M:%S ", self.clock())
        out = []
        for part in s.splitlines(keepends=True):
            if self._bol:
                out.append(stamp)
            out.append(part)
            self._bol = part.endswith("\n")
        try:
            os.write(self.fd, "".join(out).replace("\r\n", "\n").encode("utf-8", "replace"))
        except OSError:
            pass
        return len(s)

    def flush(self):
        pass                           # os.write is unbuffered

    def writable(self) -> bool:
        return True

    def close(self):
        if self.fd >= 0 and self.target is None:
            os.close(self.fd)
        self.fd = -1
