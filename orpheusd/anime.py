"""Anime as a third source, by driving ani-cli instead of rewriting it.

ani-cli already knows how to find a show, list its episodes and turn an episode
into a playable URL, and it tracks the scrapers as they break. Reimplementing
that would be signing up to maintain it. So this module treats ani-cli as a
RESOLVER: ask it the three questions, take the stream URL, and play it in
Orpheus' own window, where it gets the same transport and the same Hyprland
rules as every other video.

It has no machine-readable mode, so both answers come out through hooks it
already has:

  ANI_CLI_MENU    a menu program that copies the candidate list to a file and
                  chooses nothing (`bin/orpheus-ani-menu`), which is how the
                  series list and the episode list get out.
  ANI_CLI_PLAYER  a player whose name contains `mpv`, so ani-cli hands it the
                  referrer and the subtitle track along with the URL
                  (`bin/orpheus-mpv-ani`), which is how a playable stream gets
                  out. A hianime URL without its referrer is a 403.

Curd is deliberately NOT driven this way. It has to own mpv to do AniList sync,
intro skipping and Discord presence, so Orpheus hands over to it instead and
gets out of the way.

A show is addressed by (query, index) because that is all ani-cli's `-S` takes:
the nth result for a search. Resolved stream URLs are never logged.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
try:
    import pty
except ImportError:  # Windows: ani-cli is a bash script and needs a tty anyway
    pty = None
import re
import shutil
import tempfile
import time
from pathlib import Path

log = logging.getLogger("orpheus.anime")

BIN = Path(__file__).resolve().parent.parent / "bin"
MENU = BIN / "orpheus-ani-menu"
PLAYER = BIN / "orpheus-mpv-ani"

SEARCH_TTL = 15 * 60
EPISODE_TTL = 10 * 60
# A hianime URL is signed for a while, but re-resolving is cheap next to a
# failed play.
STREAM_TTL = 10 * 60

_ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")


class AnimeError(RuntimeError):
    pass


def _clean(text: str) -> str:
    return _ANSI.sub("", text).replace("\r", "").strip()


def _why(stderr: str, fallback: str) -> str:
    """ani-cli's last complaint, which is the only useful line in its output."""
    lines = [l.strip() for l in _clean(stderr).splitlines() if l.strip()]
    return (lines[-1] if lines else fallback)[:200]


class Anime:
    def __init__(self, runtime_dir: Path):
        self.runtime_dir = runtime_dir
        self._searches: dict[str, tuple[float, list[dict]]] = {}
        self._episodes: dict[str, tuple[float, list[dict]]] = {}
        self._streams: dict[str, tuple[float, dict]] = {}

    @property
    def available(self) -> bool:
        return pty is not None and bool(shutil.which("ani-cli"))

    @property
    def curd(self) -> bool:
        # Curd is opened in a Linux terminal; on Windows it has no launcher yet.
        return pty is not None and bool(shutil.which("curd"))

    def _scratch(self, suffix: str) -> Path:
        # One file per call: two searches at once must not read each other's
        # answer.
        fd, name = tempfile.mkstemp(prefix="ani-", suffix=suffix, dir=self.runtime_dir)
        os.close(fd)
        return Path(name)

    # ---- driving ani-cli ---------------------------------------------------

    async def _ani(self, args: list[str], env: dict, timeout: float = 120) -> tuple[int, str]:
        """Run ani-cli with nobody at the keyboard.

        **It needs a tty on stdin.** With stdin closed or piped, ani-cli decides
        it was not opened from a terminal and replaces ANI_CLI_MENU with rofi or
        dmenu - which puts a menu on the user's screen, from a daemon, with no
        way to answer it. A pty costs two file descriptors and avoids that
        entirely. Nothing writes to the tty: output goes to pipes.
        """
        full = dict(os.environ, ANI_CLI_MENU=str(MENU), ANI_CLI_LOG="0", **env)
        master, slave = pty.openpty()
        try:
            proc = await asyncio.create_subprocess_exec(
                "ani-cli", *args, env=full, stdin=slave,
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        finally:
            os.close(slave)
        try:
            _, err = await asyncio.wait_for(proc.communicate(), timeout)
        except asyncio.TimeoutError:
            proc.kill()
            raise AnimeError("ani-cli took too long to answer")
        finally:
            os.close(master)
        return proc.returncode or 0, err.decode(errors="replace")

    async def _ask(self, args: list[str], env: dict | None = None,
                   timeout: float = 120) -> tuple[str, list[str]]:
        """Run ani-cli for one of its lists. Returns (prompt, lines).

        Choosing nothing is how the list gets out, so a non-zero exit is the
        normal outcome here and the dump file is the real answer.
        """
        dump = self._scratch(".list")
        _, err = await self._ani(args, dict(env or {}, ORPHEUS_ANI_DUMP=str(dump)), timeout)
        try:
            text = dump.read_text(errors="replace")
        finally:
            dump.unlink(missing_ok=True)
        lines = [l for l in text.splitlines() if l.strip()]
        if not lines or not lines[0].startswith("prompt\t"):
            raise AnimeError(_why(err, "ani-cli found nothing"))
        return lines[0].split("\t", 1)[1].strip().rstrip(":"), lines[1:]

    # ---- asking ------------------------------------------------------------

    async def search(self, query: str) -> list[dict]:
        query = (query or "").strip()
        if not query:
            return []
        hit = self._searches.get(query.lower())
        if hit and time.time() - hit[0] < SEARCH_TTL:
            return hit[1]

        prompt, lines = await self._ask([query])
        # ani-cli skips the menu when a search has exactly one hit and goes
        # straight on to the episodes, so the title never reaches us. The query
        # stands in for it until the player reports the real one.
        if prompt.lower().startswith("select episode"):
            items = [self._show(query, 1, query, len(lines))]
        else:
            items = []
            for line in lines:
                n, _, title = line.partition(" ")
                if n.isdigit() and title.strip():
                    items.append(self._show(query, int(n), title.strip()))
        self._searches[query.lower()] = (time.time(), items)
        return items

    async def episodes(self, query: str, index: int) -> list[dict]:
        query = (query or "").strip()
        if not query:
            return []
        key = f"{index}@{query.lower()}"
        hit = self._episodes.get(key)
        if hit and time.time() - hit[0] < EPISODE_TTL:
            return hit[1]

        prompt, lines = await self._ask(["-S", str(index), query])
        if not prompt.lower().startswith("select episode"):
            raise AnimeError("no episodes for that series")
        items = [self._episode(query, index, ep.strip()) for ep in lines if ep.strip()]
        self._episodes[key] = (time.time(), items)
        return items

    async def resolve(self, query: str, index: int, ep: str, quality: str = "best") -> dict:
        """A stream URL for the video window, with what it needs to be fetched."""
        key = f"{index}@{query.lower()}#{ep}:{quality}"
        hit = self._streams.get(key)
        if hit and time.time() - hit[0] < STREAM_TTL:
            return hit[1]

        out = self._scratch(".json")
        out.unlink(missing_ok=True)
        after = self._scratch(".list")
        # The dump file catches the "next / replay / quit" menu ani-cli shows
        # after it starts playing, which is what ends the run. With a non-fzf
        # menu ani-cli waits for the player before it gets there, so by the time
        # this returns the shim has already written its answer.
        _, err = await self._ani(
            ["-S", str(index), "-e", str(ep), "-q", quality, query],
            {"ORPHEUS_ANI_DUMP": str(after),
             "ORPHEUS_ANI_RESOLVE": str(out),
             "ANI_CLI_PLAYER": str(PLAYER)})
        after.unlink(missing_ok=True)
        if not out.exists():
            raise AnimeError(_why(err, "no sources for that episode"))
        try:
            got = json.loads(out.read_text(errors="replace"))
        except ValueError:
            raise AnimeError("could not read the stream ani-cli found")
        finally:
            out.unlink(missing_ok=True)
        if not got.get("url"):
            raise AnimeError("no sources for that episode")
        self._streams[key] = (time.time(), got)
        return got

    def forget(self, query: str, index: int, ep: str) -> None:
        pre = f"{index}@{(query or '').lower()}#{ep}:"
        for k in [k for k in self._streams if k.startswith(pre)]:
            self._streams.pop(k, None)

    # ---- shaping -----------------------------------------------------------
    #
    # Two kinds, in the same vocabulary the video section uses for YouTube:
    # a `show` opens, a `video` plays.

    @staticmethod
    def _show(query: str, index: int, title: str, episodes: int = 0) -> dict:
        return {
            "kind": "show",
            "provider": "anime",
            "id": f"{index}@{query}",
            "title": title,
            "query": query,
            "index": index,
            "episodes": episodes,
        }

    @staticmethod
    def _episode(query: str, index: int, ep: str) -> dict:
        return {
            "kind": "video",
            "provider": "anime",
            "id": f"{index}@{query}#{ep}",
            "title": f"episode {ep}",
            "query": query,
            "index": index,
            "ep": ep,
            "duration": 0,
        }
