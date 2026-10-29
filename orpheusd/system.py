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
