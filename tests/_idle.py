"""Subprocesses for tests, started the way the daemon starts its own: idle
priority, no console window, one BLAS thread, stdin closed unless given.
The tests run one at a time (unittest's default), so this is all the
throttling there is."""
import os
import subprocess
import sys

WINDOWS = sys.platform == "win32"
FLAGS = (0x40 | 0x08000000) if WINDOWS else 0   # IDLE_PRIORITY_CLASS | CREATE_NO_WINDOW
THREADS = {"OPENBLAS_NUM_THREADS": "1", "OMP_NUM_THREADS": "1", "MKL_NUM_THREADS": "1"}


def _kw(kw: dict) -> dict:
    kw = dict(kw)
    kw["env"] = dict(kw.get("env") or os.environ, **THREADS)
    if WINDOWS:
        kw["creationflags"] = kw.get("creationflags", 0) | FLAGS
    else:
        kw.setdefault("preexec_fn", lambda: os.nice(19))   # tests are single-threaded
    if "input" not in kw and "stdin" not in kw:
        kw["stdin"] = subprocess.DEVNULL
    return kw


def run(cmd, **kw) -> subprocess.CompletedProcess:
    kw.setdefault("capture_output", True)
    kw.setdefault("timeout", 120)
    return subprocess.run(cmd, **_kw(kw))


def popen(cmd, **kw) -> subprocess.Popen:
    kw.pop("input", None)
    return subprocess.Popen(cmd, **_kw(kw))
