# Navidrome Provider Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Play a self-hosted Navidrome library through Orpheus — search, album/artist pages, queueing, drop-map analysis and server-side scrobbling — as a provider beside TIDAL.

**Architecture:** A `Navidrome` Subsonic client in the daemon (mirroring `YouTube`'s source surface plus browse/scrobble), registered in `Player.sources["navidrome"]`; `/search` merges its tagged results; `/{album|artist}/{id}` accepts `?provider=navidrome`; the analysis gate allowlists the provider; Tracker's scrobble callbacks route Navidrome tracks to the server. The UI passes `provider` through navigation and marks rows with an `nd` chip.

**Tech Stack:** Python 3.12 (aiohttp), Subsonic REST API v1.16.1, QML.

**Spec:** `docs/superpowers/specs/2026-11-13-navidrome-design.md`

## Global Constraints

- Config keys (daemon-read only): `navidromeUrl`, `navidromeUser`, `navidromePass`; any empty/missing → `available == False` and zero behavior change anywhere.
- Every entry the client emits carries `"provider": "navidrome"`.
- Subsonic auth on every request: `u`, `t` = md5((password + salt).encode()), `s` = fresh random salt (≥ 8 hex chars), `v=1.16.1`, `c=Orpheus`, `f=json`.
- The LB/Last.fm scrobbler stays TIDAL-only (scrobble.py:124 untouched).
- No download/rip functionality of any kind.
- Tests: `PATH=~/.local/share/mise/installs/uv/0.13.8/uv-x86_64-unknown-linux-gnu:$PATH uv run --with pytest python -m pytest tests/ -q` — all existing tests keep passing.

## Review Focus

1. A `navidromeUrl` typed with a trailing slash (or `/rest` suffix) must still produce correct endpoints — Task 1 test.
2. Non-ASCII search queries and passwords must not crash auth or search (utf-8 md5, URL-encoded params) — Task 1 test.
3. Wrong credentials (Subsonic error 40) must degrade: search returns TIDAL-only results, `/status` reports `navidromeOk: false`, nothing raises to the route — Tasks 1–2 tests.
4. A Navidrome track restored from the saved queue after a daemon restart must resolve and play without a TIDAL login — Task 2 test.
5. Cover URLs must carry auth (a LAN Navidrome rejects bare `getCoverArt`) — Task 1 entry-mapping test.

---

### Task 1: The Subsonic client

**Files:**
- Create: `orpheusd/navidrome.py`
- Test: `tests/test_navidrome.py` (aiohttp `TestServer` fake Subsonic, patterned on tests/test_shaders.py's TestClient use)

**Interfaces:**
- Produces `class Navidrome` (all methods `async` unless noted):
  - `__init__(self, url: str, user: str, password: str)`; `available: bool` (property, non-async) — false when any field is blank after strip. URL normalized: trailing `/` and trailing `/rest` stripped.
  - `rest_url(self, endpoint: str, **q) -> str` (non-async) — full authed URL, used for `stream`/`getCoverArt` and by tests.
  - `search(self, query: str) -> dict` → `{"tracks": [...], "albums": [...], "artists": [...], "playlists": []}` via `search3` with `songCount=20, albumCount=20, artistCount=20`.
  - `album(self, album_id: str) -> dict` → `{"album": <album entry>, "tracks": [<track entry>...]}` via `getAlbum`.
  - `artist(self, artist_id: str) -> dict` → `{"artist": <artist entry>, "albums": [<album entry>...]}` via `getArtist`.
  - `stream(self, track_id: str) -> dict` → `{"url": rest_url("stream", id=track_id, format="raw"), "quality": <"LOSSLESS" when suffix in (flac, alac, wav) else uppercased suffix or "">, "codec": suffix, "bitDepth": None, "sampleRate": None}` (song metadata via `getSong`).
  - `forget(self, track_id: str) -> None` (non-async) — no-op.
  - `ping(self) -> bool` — True on `status == "ok"`; result cached 30 s.
  - `scrobble(self, track_id: str, submission: bool) -> None` — GET `/rest/scrobble` with `id`, `submission=true|false`; swallows all errors (logged).
  - `NavidromeError(RuntimeError)` raised by browse/search/stream on transport failure or `status != "ok"` (message from the Subsonic `error.message` when present).
  - Entry shapes (each with `"provider": "navidrome"`): track `{kind:"track", id, title, artist, artists:[names], album, albumId, duration:int, hires:False, cover}`; album `{kind:"album", id, title, artist, artistId, year, cover}`; artist `{kind:"artist", id, name, cover}`. `cover` = `rest_url("getCoverArt", id=<coverArt id>, size=640)` or `""`.

- [ ] **Step 1: Write the failing tests.** The fake server records each request's path and query and answers canned Subsonic JSON (`{"subsonic-response": {"status": "ok", ...}}`). Tests:

```python
async def test_auth_params_and_token(self):      # u, s, v=1.16.1, c=Orpheus, f=json present;
    # t == md5(("pw" + s).encode()).hexdigest(); fresh s per request
async def test_url_normalized(self):             # "http://x:4533/" and "http://x:4533/rest" both -> ".../rest/ping"
async def test_unavailable_when_blank(self):     # password "" -> available False
async def test_search_maps_and_tags(self):       # search3 song/album/artist -> entry shapes, provider tagged,
    # playlists == [], unicode query round-trips URL-encoded
async def test_album_and_artist_shapes(self):    # album() and artist() per Interfaces
async def test_stream_url_and_quality(self):     # url contains /rest/stream, id, auth; flac -> LOSSLESS, mp3 -> MP3
async def test_error_status_raises(self):        # {"status":"failed","error":{"code":40,"message":"Wrong username"}}
    # -> NavidromeError("Wrong username"); ping() -> False, not raise
async def test_scrobble_swallows_and_submits(self):  # hits /rest/scrobble with submission=true; server 500 -> no raise
async def test_cover_url_carries_auth(self):     # track entry cover has u/t/s params
```

- [ ] **Step 2: Run to verify failure.** `... pytest tests/test_navidrome.py -q` — FAIL (module missing).
- [ ] **Step 3: Implement `orpheusd/navidrome.py`** per Interfaces. One shared `aiohttp.ClientSession` created lazily; 10 s timeouts; `hashlib.md5`, `secrets.token_hex(8)` for salt.
- [ ] **Step 4: Run to verify pass**, then the whole suite.
- [ ] **Step 5: Commit.** `git add orpheusd/navidrome.py tests/test_navidrome.py && git commit -m "navidrome: a Subsonic client in the daemon"`

### Task 2: Registration, status, search merge, item routes, queue restore

**Files:**
- Modify: `orpheusd/__main__.py` (init ~line 70-80, status providers ~line 230, `search` ~line 489, `item` ~line 494)
- Test: extend `tests/test_navidrome.py`

**Interfaces:**
- Consumes: Task 1's `Navidrome`, `NavidromeError`.
- Produces:
  - App init: `self.navidrome = Navidrome(cfg("navidromeUrl"), cfg("navidromeUser"), cfg("navidromePass"))` (config read the way scrobble.py reads its keys) and, when `available`, `self.sources["navidrome"] = self.navidrome` BEFORE `Player(...)` is constructed.
  - `/status` providers block gains `"navidrome": <available>`, and a top-level `"navidromeOk": <last ping result>` refreshed opportunistically (ping fired on status when available, cached by the client).
  - Module-level `def merge_search(base: dict, extra: dict) -> dict` in `orpheusd/navidrome.py` — appends extra's tracks/albums/artists to base's lists, leaves playlists alone; tolerates missing keys.
  - `search` route: when `self.navidrome.available`, run TIDAL (only if signed in) and Navidrome concurrently (`asyncio.gather(..., return_exceptions=True)`); either side failing (or signed out) contributes empties; `need_login()` is raised only when NEITHER TIDAL is signed in NOR Navidrome is available.
  - `item` route: `req.query.get("provider") == "navidrome"` and kind in (album, artist) → `self.navidrome.album/artist(id)`; `need_login()` skipped on that path.

- [ ] **Step 1: Write the failing tests** (handler-free where possible):

```python
def test_merge_search(self):                     # tidal lists first, navidrome appended; missing keys fine
async def test_search_degrades_per_side(self):   # fake navidrome raising NavidromeError -> tidal results alone;
    # and a fake tidal raising -> navidrome results alone (call the gather/merge helper with stubs)
async def test_player_resolves_navidrome_without_tidal(self):
    # Player(tidal=None-ish stub, sources={"navidrome": fake}) ._resolve({"provider":"navidrome","id":"t1"})
    # returns the fake's stream dict and never touches tidal  (queue-restore-after-restart guarantee)
```

The search-degrade test needs the route's gather factored into `async def search_all(tidal_search, navidrome, q) -> dict` (module function in navidrome.py taking the TIDAL search coroutine-factory or None) — the route calls it; the test calls it with stubs.

- [ ] **Step 2: Run to verify failure.**
- [ ] **Step 3: Implement** init/registration, `merge_search`, `search_all`, route changes, status fields.
- [ ] **Step 4: Full suite passes.**
- [ ] **Step 5: Commit.** `"navidrome: registered as a source; search merges; album and artist pages"`

### Task 3: Analysis gate

**Files:**
- Modify: `orpheusd/analysis.py` (`skip_reason`, ~line 130)
- Test: `tests/test_analysis.py` (extend where skip_reason is covered)

**Interfaces:**
- Produces: `skip_reason` returns `"provider"` only for providers NOT in `(None, "", "navidrome")`.

- [ ] **Step 1: Failing test:** `skip_reason({"provider": "navidrome", "duration": 200, ...})` is None (given analysis on/available as the existing tests arrange); `{"provider": "youtube"}` still `"provider"`.
- [ ] **Step 2: Verify fail.** **Step 3: One-line change.** **Step 4: Suite green.** **Step 5: Commit** `"analysis: the drop map covers navidrome tracks"` — Pilgrimage now works on the self-hosted library.

### Task 4: Scrobbling to the server

**Files:**
- Modify: `orpheusd/__main__.py` (Tracker construction ~line 92, scrobble flush path ~line 202)
- Test: extend `tests/test_navidrome.py`

**Interfaces:**
- Consumes: `Navidrome.scrobble(id, submission)`.
- Produces: module function in navidrome.py `def route_scrobble(navidrome, fallback, track: dict, *args) -> None` — when `track.get("provider") == "navidrome"` and navidrome is available, fire-and-forget `navidrome.scrobble(track["id"], submission)` (submission False for the now-playing wrapper, True for the scrobble wrapper — expose as two partials or a `submission` arg); otherwise call `fallback(track, *args)`. `__main__` wraps `Tracker(self.history, now_playing_wrapper, scrobble_wrapper)` and the line-202 flush with it.

- [ ] **Step 1: Failing tests:** navidrome track routes to a recorded fake with the right `submission` and never reaches the fallback; TIDAL track reaches the fallback untouched; navidrome-unavailable routes to fallback.
- [ ] **Step 2–4: fail → implement → suite green.**
- [ ] **Step 5: Commit** `"navidrome: plays scrobble to the server"`

### Task 5: UI plumbing, settings note, README

**Files:**
- Modify: `Library.qml` (row chip ~line 239, page fetch ~line 529, album/artist row activation sites found by `grep -n "go({" Library.qml`), `SettingsPane.qml` (a note row near the scrobbling/connections rows), `README.md` (More-than-TIDAL section)

**Interfaces:**
- Consumes: `/status` fields `providers.navidrome`, `navidromeOk`; entries carrying `provider`.

- [ ] **Step 1: Page fetch carries the provider.** Line 529 becomes `api.get("/" + p.kind + "/" + p.id + (p.provider ? "?provider=" + p.provider : ""), ...)`; every `go({kind: "album"/"artist", id: ...})` call site forwards `provider: it.provider` from its row item (find all with grep; rows for TIDAL items have no provider field, so the ternary no-ops).
- [ ] **Step 2: The chip.** In the track-row text at ~line 239, the HR slot becomes: `(it.hires ? " HR " : it.provider === "navidrome" ? " nd " : "    ")`; album/artist rows get the same dim `nd` marker where they show HR/metadata text.
- [ ] **Step 3: Settings note.** Where scrobbling status rows live in SettingsPane's rows(): when `api.status.providers && api.status.providers.navidrome`, push `{kind: "note", label: "navidrome · " + host + " · " + (api.status.navidromeOk ? "reachable" : "unreachable")}` (host parsed from status? the daemon adds `navidromeHost` — add it in Task 2's status block as the URL's host for display).
- [ ] **Step 4: README.** In More-than-TIDAL: a short paragraph — self-hosted Navidrome via `navidromeUrl`/`navidromeUser`/`navidromePass` in config.json; results join search tagged `nd`; drop map and scrobbling included; no downloading.
- [ ] **Step 5: Verify.** Full suite (test_qml_ids parses the QML). Commit `"navidrome: search chips, page navigation, settings note, readme"`

### Task 6: Whole-branch verification

- [ ] **Step 1:** Full suite green.
- [ ] **Step 2:** Diff re-read against the spec's §2 goals and non-goals.
- [ ] **Step 3:** Live smoke: if the user's Navidrome is reachable (config present), `curl /search` and play one track end-to-end; otherwise run the fake-server flow once via tests only, and say so in the report.
- [ ] **Step 4:** Final review (superpowers:requesting-code-review), fix pass, ledger.

## Execution notes

- Task order: 1 → 2 → 3 → 4 → 5 → 6.
- `self.navidrome` must exist before `Player` gets `self.sources` (Task 2) — sources is passed by reference at line ~78, but registering before construction keeps it obvious.
