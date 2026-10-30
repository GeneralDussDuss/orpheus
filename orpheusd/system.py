"""What differs between Linux and Windows: where Orpheus keeps its files, and how
it reaches mpv's JSON IPC.

mpv serves IPC on a Unix socket on Linux and on a named pipe on Windows. Both
come back as an asyncio (reader, writer) pair, so nothing past `ipc_connect`
knows which it got.
"""
from __future__ import annotations

import asyncio
import glob
import os
import shutil
import sys
import tempfile
import time
from pathlib import Path

WINDOWS = sys.platform == "win32"


def _dirs() -> tuple[Path, Path, Path]:
    if WINDOWS:
        base = Path(os.environ.get("LOCALAPPDATA") or Path.home() / "AppData" / "Local") / "Orpheus"
        return base / "state", base / "cache", Path(tempfile.gettempdir()) / "orpheus"
    home = Path.home()
    return (Path(os.environ.get("XDG_STATE_HOME", home / ".local/state")) / "orpheus",
            Path(os.environ.get("XDG_CACHE_HOME", home / ".cache")) / "orpheus",
            Path(os.environ.get("XDG_RUNTIME_DIR", "/tmp")) / "orpheus")


STATE_DIR, CACHE_DIR, RUNTIME_DIR = _dirs()


def mpv_path() -> str:
    """mpv on PATH, or where Windows installers put it: winget and Chocolatey
    only reach PATH in a new shell, so a fresh install would not be found.
    ORPHEUS_MPV overrides both."""
    found = os.environ.get("ORPHEUS_MPV") or shutil.which("mpv")
    if found or not WINDOWS:
        return found or "mpv"
    env = lambda v: os.environ.get(v, "")
    for pattern in (rf"{env('LOCALAPPDATA')}\Microsoft\WinGet\Links\mpv.exe",
                    rf"{env('LOCALAPPDATA')}\Microsoft\WinGet\Packages\*mpv*\**\mpv.exe",
                    rf"{env('ProgramFiles')}\mpv\mpv.exe",
                    rf"{env('ProgramFiles')}\MPV Player\mpv.exe",   # winget's shinchiro.mpv
                    rf"{env('LOCALAPPDATA')}\Programs\mpv\mpv.exe",
                    rf"{env('LOCALAPPDATA')}\mpv\mpv.exe",
                    rf"{env('ProgramFiles(x86)')}\mpv\mpv.exe",
                    rf"{env('USERPROFILE')}\scoop\shims\mpv.exe",
                    rf"{env('ProgramData')}\chocolatey\bin\mpv.exe",
                    rf"{env('ProgramData')}\chocolatey\lib\mpv*\**\mpv.exe"):
        hits = glob.glob(pattern, recursive=True)
        if hits:
            return hits[0]
    return "mpv"


def curd_path() -> str | None:
    """Curd on PATH, or where its Windows installer puts it (per user, never on PATH)."""
    found = shutil.which("curd")
    if found or not WINDOWS:
        return found
    exe = Path(os.environ.get("APPDATA", "")) / "Curd" / "curd.exe"
    return str(exe) if exe.is_file() else None


def ipc_address(runtime_dir: Path, name: str) -> str:
    """Where an mpv instance called `name` should serve its IPC."""
    if WINDOWS:
        # Pipe names are machine-wide, so a second daemon must not collide.
        return rf"\\.\pipe\orpheus-{name}-{os.getpid()}"
    return str(runtime_dir / f"{name}.sock")


def ipc_clear(address: str) -> None:
    """Remove a stale socket left by a crashed mpv. Pipes vanish on their own."""
    if not WINDOWS:
        Path(address).unlink(missing_ok=True)


async def ipc_connect(address: str, attempts: int = 100):
    """Connect once mpv has opened its IPC, waiting up to ~5 s for it to appear."""
    for i in range(attempts):
        try:
            if not WINDOWS:
                return await asyncio.open_unix_connection(address)
            loop = asyncio.get_running_loop()
            reader = asyncio.StreamReader()
            proto = asyncio.StreamReaderProtocol(reader)
            # only Windows' proactor loop has it, hence the ignore
            transport, _ = await loop.create_pipe_connection(lambda: proto, address)  # type: ignore[attr-defined]
            return reader, asyncio.StreamWriter(transport, proto, reader, loop)
        except (FileNotFoundError, ConnectionRefusedError, OSError):
            if i == attempts - 1:
                raise
            await asyncio.sleep(0.05)
    raise ConnectionError(f"mpv IPC never appeared at {address}")


def write_atomic(path: Path, data: bytes) -> None:
    """Replace `path` with `data` so a reader, or a crash mid-write, only ever
    sees the old file or the new one. Windows refuses the rename while something
    (a virus scanner, usually) has the target open, so that is retried briefly."""
    tmp = path.with_name(path.name + ".tmp")
    with open(tmp, "wb") as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())
    for i in range(5):
        try:
            os.replace(tmp, path)
            return
        except PermissionError:
            if i == 4:
                raise
            time.sleep(0.05 * (i + 1))


_job = None


def tie_to_daemon(pid: int) -> None:
    """Make Windows kill a child (mpv) when the daemon goes, however it goes.

    The desktop app stops the daemon with TerminateProcess, which runs no
    cleanup, so an mpv left behind would keep playing with nothing driving it.
    A job object set to kill on close fixes that: its only handle is ours, and
    the kernel closes it when this process ends. Linux needs nothing here; mpv
    sees its IPC socket close and the systemd unit owns the process group."""
    global _job
    if not WINDOWS:
        return
    import ctypes
    from ctypes import wintypes
    k32 = ctypes.WinDLL("kernel32", use_last_error=True)
    k32.CreateJobObjectW.restype = wintypes.HANDLE
    k32.OpenProcess.restype = wintypes.HANDLE
    k32.SetInformationJobObject.argtypes = (wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD)
    k32.AssignProcessToJobObject.argtypes = (wintypes.HANDLE, wintypes.HANDLE)
    k32.CloseHandle.argtypes = (wintypes.HANDLE,)
    if _job is None:
        class IO(ctypes.Structure):
            _fields_ = [(n, ctypes.c_ulonglong) for n in
                        ("r", "w", "o", "rb", "wb", "ob")]

        class Basic(ctypes.Structure):
            _fields_ = [("PerProcessUserTimeLimit", ctypes.c_longlong),
                        ("PerJobUserTimeLimit", ctypes.c_longlong),
                        ("LimitFlags", wintypes.DWORD),
                        ("MinimumWorkingSetSize", ctypes.c_size_t),
                        ("MaximumWorkingSetSize", ctypes.c_size_t),
                        ("ActiveProcessLimit", wintypes.DWORD),
                        ("Affinity", ctypes.c_size_t),
                        ("PriorityClass", wintypes.DWORD),
                        ("SchedulingClass", wintypes.DWORD)]

        class Extended(ctypes.Structure):
            _fields_ = [("Basic", Basic), ("Io", IO),
                        ("ProcessMemoryLimit", ctypes.c_size_t),
                        ("JobMemoryLimit", ctypes.c_size_t),
                        ("PeakProcessMemoryUsed", ctypes.c_size_t),
                        ("PeakJobMemoryUsed", ctypes.c_size_t)]

        job = k32.CreateJobObjectW(None, None)
        info = Extended()
        info.Basic.LimitFlags = 0x2000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        if not job or not k32.SetInformationJobObject(job, 9, ctypes.byref(info), ctypes.sizeof(info)):
            raise OSError(ctypes.get_last_error(), "job object")
        _job = job
    proc = k32.OpenProcess(0x0101, False, pid)  # PROCESS_TERMINATE | PROCESS_SET_QUOTA
    if not proc:
        raise OSError(ctypes.get_last_error(), "OpenProcess")
    try:
        if not k32.AssignProcessToJobObject(_job, proc):
            raise OSError(ctypes.get_last_error(), "AssignProcessToJobObject")
    finally:
        k32.CloseHandle(proc)
