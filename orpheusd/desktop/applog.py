"""desktop.log: what the desktop app says, time-stamped, size-capped and kept
for one run back, with repeats folded so a message in a loop cannot flood it."""
from __future__ import annotations

import io
import os
import time
from pathlib import Path


class CappedLog(io.TextIOBase):
    """A text stream for sys.stdout/sys.stderr under pythonw.

    The previous run's log is kept as `<name>.1` when this one opens (after a
    crash that is the one worth reading); past `limit` bytes the current file
    rolls over to `.1` too. Every line starts with the time of day."""

    def __init__(self, path: Path, limit: int = 1 << 20, clock=time.localtime):
        self.path = Path(path)
        self.limit = limit
        self.clock = clock
        self._bol = True
        self._roll()

    def _roll(self):
        old = self.path.with_name(self.path.name + ".1")
        try:
            if self.path.exists() and self.path.stat().st_size:
                os.replace(self.path, old)
        except OSError:
            pass                       # still open elsewhere: just start over
        self._f = open(self.path, "w", encoding="utf-8", buffering=1)

    def write(self, s: str) -> int:
        if not s:
            return 0
        if self._f.tell() > self.limit:
            self._f.close()
            self._roll()
        stamp = time.strftime("%H:%M:%S ", self.clock())
        out = []
        for part in s.splitlines(keepends=True):
            if self._bol:
                out.append(stamp)
            out.append(part)
            self._bol = part.endswith("\n")
        self._f.write("".join(out))
        return len(s)

    def flush(self):
        self._f.flush()

    def writable(self) -> bool:
        return True

    def close(self):
        self._f.close()


class Repeats:
    """Fold a message that keeps coming: the first goes through, the repeats
    inside `window` seconds are counted, and the count is reported when a
    different message arrives or the window ends."""

    def __init__(self, window: float = 60.0, clock=time.monotonic):
        self.window = window
        self.clock = clock
        self.last = None
        self.since = 0.0
        self.count = 0

    def feed(self, msg: str) -> list[str]:
        """The lines to write for `msg` (possibly none)."""
        now = self.clock()
        out = []
        if msg == self.last and now - self.since < self.window:
            self.count += 1
            return out
        if self.count:
            out.append(f"(last message repeated {self.count} more time{'s' if self.count > 1 else ''})")
        self.last, self.since, self.count = msg, now, 0
        out.append(msg)
        return out
