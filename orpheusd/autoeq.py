"""AutoEq headphone corrections, found by name and fetched on request.

Orpheus ships no AutoEq data (see the licence note in eq.py): the
measurements belong to oratory1990, crinacle, Rtings and the rest, none of whom
have granted redistribution. What ships is a way to look a headphone up in
AutoEq's public repository and pull that one correction to the user's own
machine, the way a browser would.

- The index is AutoEq's results/INDEX.md, one plain GET (no GitHub API, so no
  rate limit), parsed to rows and cached as CACHE_DIR/autoeq/index.json. It
  is fetched lazily on the first search and refreshed in the background once
  it is a month old; a stale index keeps answering while that runs.
- A device's ParametricEQ.txt is fetched once and cached raw under a hash of
  its path (display names repeat across sources and carry every punctuation
  mark there is, so they make poor filenames).
- Search runs here, not in the client: the index is ~9k rows and never
  travels in /eq or /status.

The parsed filters are stored in the EQ state itself (daemon.json), so a
chosen correction plays after a restart with the network unplugged. Nothing
here imports numpy; the daemon-only install runs it as is.
"""

from __future__ import annotations

import asyncio
import hashlib
import json
import logging
import re
import time
from pathlib import Path
from urllib.parse import quote, unquote

import aiohttp
from aiohttp import web

from . import eq as eqmod
from .lyrics import UA
from .system import write_atomic

log = logging.getLogger("orpheus.autoeq")

RAW = "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/"
INDEX_URL = RAW + "INDEX.md"
INDEX_V = 1
INDEX_TTL = 30 * 86400
INDEX_FLOOR = 1000          # fewer rows than this is a captive portal, not AutoEq
RETRY_AFTER = 60.0          # s between automatic index attempts after a failure
MAX_RESULTS = 200           # hard cap on ?limit
MAX_RECENT = 20
DEVICE_MAX = 64 * 1024      # a ParametricEQ.txt is ~500 B
INDEX_MAX = 8 * 1024 * 1024
# AutoEq's own recommendation order; anything else ranks after, alphabetically.
SOURCE_RANK = ["oratory1990", "crinacle", "Rtings", "Innerfidelity", "Super Review",
               "Headphone.com Legacy", "Kuulokenurkka"]
_RANK = {s: i for i, s in enumerate(SOURCE_RANK)}

# - [Sennheiser HD 600](./oratory1990/over-ear/Sennheiser%20HD%20600) by oratory1990
# - [64 Audio A12t](./crinacle/GRAS%20RA0045%20in-ear/64%20Audio%20A12t) by crinacle on GRAS RA0045
# `link` is greedy up to the LAST ") by ": names carry "(passive)" and the like.
_LINE_RE = re.compile(r"^- \[(?P<name>[^\]]+)\]\(\./(?P<link>.+)\) by (?P<source>.+?)(?: on (?P<rig>.+))?$")
_PATH_RE = re.compile(r"^[^/\\]+/[^/\\]+/[^/\\]+$")       # exactly source/form/name, decoded
_SQUASH = re.compile(r"[^a-z0-9]+")


class AutoEqError(Exception):
    def __init__(self, msg: str, http: int = 502):
        super().__init__(msg)
        self.msg, self.http = msg, http


# ---- pure helpers -----------------------------------------------------------

def parse_index(text: str) -> list[list[str]]:
    """INDEX.md to rows [name, source, rig, form, path], in file order."""
    rows = []
    for line in (text or "").splitlines():
        m = _LINE_RE.match(line.rstrip())
        if not m:
            continue                   # the header, blank lines, anything odd
        path = unquote(m.group("link"))
        segs = path.split("/")
        if len(segs) != 3 or not all(segs):
            continue
        form = segs[1].split()[-1] if segs[1].split() else ""
        rows.append([m.group("name"), m.group("source"), m.group("rig") or "", form, path])
    return rows


def entry_from_path(path: str) -> dict:
    """An entry from the path alone, for a device applied while the index is
    absent. The rig is whatever precedes the form in the folder name."""
    seg0, seg1, seg2 = (path.split("/") + ["", "", ""])[:3]
    words = seg1.split()
    return {"name": seg2, "source": seg0, "rig": " ".join(words[:-1]),
            "form": words[-1] if words else "", "path": path}


def _check_path(path) -> list[str]:
    if (not isinstance(path, str) or len(path) > 300 or ".." in path
            or path.startswith("/") or not _PATH_RE.match(path)):
        raise AutoEqError("bad path", 400)
    return path.split("/")


def device_url(path: str) -> str:
    """The raw ParametricEQ.txt for a decoded index path. The host is fixed;
    nothing the client sends reaches the URL's authority."""
    segs = _check_path(path)
    return (RAW + "/".join(quote(s, safe="()") for s in segs) + "/"
            + quote(segs[2], safe="()") + "%20ParametricEQ.txt")


def _starts_word(hay: str, token: str) -> bool:
    i = hay.find(token)
    while i >= 0:
        if i == 0 or not hay[i - 1].isalnum():
            return True
        i = hay.find(token, i + 1)
    return False


def score(entry_lc: tuple, tokens: list[str], q: str) -> int | None:
    """How well a row matches; None means it does not.

    `entry_lc` is the row's precomputed (name, "name source rig", and both
    squashed to bare alphanumerics). Every token must appear somewhere, either
    as typed or squashed, so "hd600" finds "HD 600". The name counts for more
    than the source or rig, and a match at the start of a word for more still.
    """
    name, hay, name_sq, hay_sq = entry_lc
    pts = 0
    for t in tokens:
        if t in name:
            pts += 10 if _starts_word(name, t) else 3
        elif t in hay:
            pts += 1
        else:
            ts = _SQUASH.sub("", t)
            if ts and ts in name_sq:
                pts += 3
            elif ts and ts in hay_sq:
                pts += 1
            else:
                return None
    qs = _SQUASH.sub("", q)
    if name == q or (qs and name_sq == qs):
        pts += 100
    if name.startswith(q) or (qs and name_sq.startswith(qs)):
        pts += 60
    elif q in name or (qs and qs in name_sq):
        pts += 30
    return pts


def _lc(row: list[str]) -> tuple:
    name = row[0].lower()
    hay = f"{name} {row[1].lower()} {row[2].lower()}"
    return name, hay, _SQUASH.sub("", name), _SQUASH.sub("", hay)


def _rank(source: str) -> tuple:
    return (_RANK[source], "") if source in _RANK else (len(SOURCE_RANK), source.lower())


def _entry(row: list[str]) -> dict:
    return {"name": row[0], "source": row[1], "rig": row[2], "form": row[3], "path": row[4]}


def _as_text(raw, cap: int) -> str | None:
    if raw is None:
        return None
    if isinstance(raw, str):
        raw = raw.encode("utf-8")
    if len(raw) > cap:
        return None
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        return None


async def _fetch(url: str) -> bytes | None:
    """One GET, or None. Never raises: every caller treats None as offline."""
    try:
        timeout = aiohttp.ClientTimeout(total=20)
        async with aiohttp.ClientSession(timeout=timeout, headers={"User-Agent": UA}) as s:
            async with s.get(url) as r:
                if r.status != 200:
                    log.debug("autoeq: %s returned %s", url, r.status)
                    return None
                return await r.content.read(INDEX_MAX + 1)
    except Exception as e:
        log.debug("autoeq: fetching %s failed: %s", url, e)
        return None


# ---- the service --------------------------------------------------------------

class AutoEq:
    def __init__(self, cache_dir: Path, fetch=None):
        self.dir = Path(cache_dir) / "autoeq"
        self.devdir = self.dir / "devices"
        self._fetch = fetch or _fetch
        self.rows: list[list[str]] | None = None
        self._lcs: list[tuple] = []
        self._by_path: dict[str, list[str]] = {}
        self.fetched_at = 0.0
        self.error = ""
        self._load_task: asyncio.Task | None = None
        self._failed_at = 0.0
        self._task: asyncio.Task | None = None

    # -- index --

    @property
    def refreshing(self) -> bool:
        return self._task is not None and not self._task.done()

    def _set_rows(self, rows: list[list[str]], fetched_at: float) -> None:
        self.rows = rows
        self._lcs = [_lc(r) for r in rows]
        self._by_path = {r[4]: r for r in rows}
        self.fetched_at = fetched_at

    def _read_index(self):
        try:
            d = json.loads((self.dir / "index.json").read_text(encoding="utf-8"))
        except Exception:
            return None
        rows = d.get("rows") if isinstance(d, dict) and d.get("v") == INDEX_V else None
        if not isinstance(rows, list):
            return None
        rows = [r for r in rows if isinstance(r, list) and len(r) == 5 and all(isinstance(x, str) for x in r)]
        return (rows, float(d.get("fetchedAt") or 0)) if rows else None

    async def _ensure_loaded(self) -> None:
        # Loaded once, on the first search, never at daemon start. Single-flight:
        # a second search during the ~1 MB read waits for it rather than seeing
        # no rows and asking github for an index that is on disk.
        if self.rows is not None:
            return
        if self._load_task is None:
            self._load_task = asyncio.get_running_loop().create_task(self._load_disk())
        await asyncio.shield(self._load_task)

    async def _load_disk(self) -> None:
        got = await asyncio.to_thread(self._read_index)
        if got and self.rows is None:
            self._set_rows(*got)

    def kick(self, force: bool = False) -> asyncio.Task | None:
        """Start a background index refresh unless one is running, or one failed
        a moment ago (the picker polls; github must not be asked every 1.5 s)."""
        if self.refreshing:
            return self._task
        if not force and self._failed_at and time.monotonic() - self._failed_at < RETRY_AFTER:
            return None
        self._task = asyncio.get_running_loop().create_task(self._refresh())
        return self._task

    async def refresh(self) -> None:
        """Fetch the index now, joining one already in flight."""
        task = self.kick(force=True)
        if task is not None:
            await task

    async def _refresh(self) -> None:
        try:
            text = _as_text(await self._fetch(INDEX_URL), INDEX_MAX)
            if text is None:
                self._fail("couldn't reach github")
                return
            rows = await asyncio.to_thread(parse_index, text)
            if len(rows) < INDEX_FLOOR:
                # a captive portal or an error page: keep what we had
                self._fail("github sent something that isn't the AutoEq index")
                return
            now = time.time()
            data = json.dumps({"v": INDEX_V, "fetchedAt": int(now), "count": len(rows), "rows": rows},
                              ensure_ascii=False, separators=(",", ":")).encode("utf-8")
            try:
                self.dir.mkdir(parents=True, exist_ok=True)
                await asyncio.to_thread(write_atomic, self.dir / "index.json", data)
            except OSError as e:
                log.debug("autoeq: couldn't cache the index: %s", e)
            self._set_rows(rows, now)
            self.error, self._failed_at = "", 0.0
            log.info("autoeq: index has %d headphones", len(rows))
        except Exception as e:                       # never into a route
            log.debug("autoeq: index refresh failed: %s", e)
            self._fail("couldn't read the AutoEq index")

    def _fail(self, msg: str) -> None:
        self.error, self._failed_at = msg, time.monotonic()

    def _age(self) -> int:
        return max(0, int((time.time() - self.fetched_at) // 86400)) if self.fetched_at else 0

    def status(self) -> dict:
        state = ("fetching" if self.refreshing and self.rows is None
                 else "ready" if self.rows is not None
                 else "offline" if self.error else "empty")
        return {"state": state, "count": len(self.rows or ()), "age": self._age(),
                "error": self.error, "refreshing": self.refreshing}

    # -- devices --

    def _sha(self, path: str) -> str:
        return hashlib.sha1(path.encode("utf-8")).hexdigest()[:20]

    def _sidecar(self) -> dict:
        try:
            d = json.loads((self.devdir / "index.json").read_text(encoding="utf-8"))
            return d if isinstance(d, dict) else {}
        except Exception:
            return {}

    def recent(self) -> list[dict]:
        """Headphones already on this machine, most recently used first."""
        side = self._sidecar()
        try:
            files = sorted(self.devdir.glob("*.txt"), key=lambda p: p.stat().st_mtime, reverse=True)
        except OSError:
            return []
        out = []
        for f in files:
            path = side.get(f.stem)
            if not isinstance(path, str):
                continue
            row = self._by_path.get(path)
            out.append(_entry(row) if row else entry_from_path(path))
            if len(out) >= MAX_RECENT:
                break
        return out

    async def device(self, path: str) -> dict:
        """{entry, text} for one device, from the cache or fetched once."""
        url = device_url(path)                       # validates; 400 on anything odd
        await self._ensure_loaded()
        row = self._by_path.get(path)
        entry = _entry(row) if row else entry_from_path(path)
        f = self.devdir / (self._sha(path) + ".txt")
        text = None
        try:
            text = f.read_bytes().decode("utf-8")
            f.touch()                                # keeps "recent" in use order
        except (OSError, UnicodeDecodeError):
            text = None
        if text is None:
            raw = await self._fetch(url)
            if raw is None:
                raise AutoEqError("couldn't download that correction (offline?)", 502)
            text = _as_text(raw, DEVICE_MAX)
            if text is None:
                raise AutoEqError("github sent something that isn't a ParametricEQ.txt", 502)
            try:
                self.devdir.mkdir(parents=True, exist_ok=True)
                write_atomic(f, text.encode("utf-8"))
                side = self._sidecar()
                side[self._sha(path)] = path
                write_atomic(self.devdir / "index.json",
                             json.dumps(side, ensure_ascii=False, indent=0).encode("utf-8"))
            except OSError as e:
                log.debug("autoeq: couldn't cache %s: %s", path, e)
        return {"entry": entry, "text": text}

    def forget(self, path: str) -> None:
        """Drop a cached file that turned out not to parse, so a retry refetches."""
        try:
            (self.devdir / (self._sha(path) + ".txt")).unlink(missing_ok=True)
        except (OSError, ValueError):
            pass

    # -- search --

    async def search(self, q: str, limit: int = 50) -> dict:
        try:
            limit = max(1, min(MAX_RESULTS, int(limit)))
        except (TypeError, ValueError):
            limit = 50
        q = " ".join((q or "").lower().split())[:120]
        await self._ensure_loaded()

        if self.rows is None:
            self.kick()
            if self.refreshing:
                return {"state": "fetching", "count": 0, "age": 0, "error": "",
                        "results": self.recent()}
            return {"state": "offline", "count": 0, "age": 0,
                    "error": "couldn't reach github · showing headphones you've used",
                    "results": self.recent()}

        if time.time() - self.fetched_at > INDEX_TTL:
            self.kick()                              # stale: refresh, keep answering
        # `refreshing` lets the picker poll until a background refresh lands
        out = {"state": "ready", "count": len(self.rows), "age": self._age(), "error": "",
               "refreshing": self.refreshing}
        if not q:
            out["results"] = self.recent()
            return out
        tokens = q.split()
        hits = []
        for row, lc in zip(self.rows, self._lcs):
            s = score(lc, tokens, q)
            if s is not None:
                hits.append((-s, _rank(row[1]), len(row[0]), lc[0], row))
        hits.sort(key=lambda h: h[:4])
        out["results"] = [_entry(h[4]) for h in hits[:limit]]
        return out


# ---- routes -----------------------------------------------------------------

def add_routes(r: web.RouteTableDef, svc: AutoEq, get_eq, set_eq, save) -> None:
    """Mount /autoeq/*. `get_eq` returns the current EQ state, `set_eq` is the
    player's (async, returns the full state), `save` persists prefs. Standalone
    so the tests can drive it on a bare app with a fake player."""

    async def _body(req) -> dict:
        try:
            b = await req.json()
            return b if isinstance(b, dict) else {}
        except Exception:
            return {}

    @r.get("/autoeq/search")
    async def autoeq_search(req):
        q = req.query.get("q", "")[:120]
        return web.json_response(await svc.search(q, req.query.get("limit", 50)))

    @r.post("/autoeq/apply")
    async def autoeq_apply(req):
        path = (await _body(req)).get("path")
        try:
            dev = await svc.device(path)
        except AutoEqError as e:
            raise (web.HTTPBadRequest if e.http == 400 else web.HTTPBadGateway)(text=e.msg)
        try:
            parsed = eqmod.parse_parametric(dev["text"])
        except ValueError as e:
            svc.forget(path)
            raise web.HTTPBadRequest(text=str(e))
        entry = dev["entry"]
        state = dict(get_eq())
        state["autoeq"] = {**{k: entry.get(k, "") for k in ("path", "name", "source", "rig", "form")},
                           "preamp": parsed["preamp"], "filters": parsed["filters"]}
        state["autoeqOn"] = True
        state["enabled"] = True
        out = dict(await set_eq(state))
        save()
        out["warnings"] = parsed["warnings"]
        return web.json_response(out)

    @r.post("/autoeq/clear")
    async def autoeq_clear(req):
        state = dict(get_eq())
        state["autoeq"], state["autoeqOn"] = None, False
        out = await set_eq(state)
        save()
        return web.json_response(out)

    @r.post("/autoeq/refresh")
    async def autoeq_refresh(req):
        await svc._ensure_loaded()
        svc.kick(force=True)
        return web.json_response(svc.status())
