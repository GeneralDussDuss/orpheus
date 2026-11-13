# Navidrome: a self-hosted library as a first-class source

Date: 2026-11-13 · Status: approved (user: "navidrome it up")

Orpheus learns to play from a self-hosted Navidrome server over the open
Subsonic API: search it, open its albums and artists, queue its tracks, and
run everything downstream — the equalizer, the visualizers, the drop map and
Pilgrimage, scrobbling — exactly as for any other track. Orpheus becomes the
player half of the user's CHARON/Navidrome setup. Downloading or ripping from
streaming services is explicitly out of scope.

## 1. What exists today (findings)

- **Providers are a dict.** `Player.sources` maps a provider name to an object
  with `stream(id) -> {"url", quality fields}` and `forget(id)`
  (orpheusd/player.py:237, 657; youtube.py's `YouTube` is the reference
  implementation). A track dict with `"provider": <name>` routes there; no
  provider means TIDAL. Everything downstream (queue, shuffle, EQ, MPRIS,
  resume, visualizers) only ever sees a URL (player.py:653-659).
- **Search** is `/search?q=` → `tidal.search` → `{tracks, albums, artists,
  playlists}` (__main__.py:489). Item pages are `/{album|playlist|mix|artist}/{id}`
  → `self.fetch` (__main__.py:494). The UI navigates with typed pages
  (`go({type: "album", id: ...})`, Library.qml:368).
- **The drop map** skips any track with a provider (analysis.py:130-131:
  `skip_reason` returns "provider"), because YouTube streams are live-ish and
  unreliable. Navidrome tracks have exact durations and stable URLs.
- **Scrobbling** (orpheusd/scrobble.py) posts to ListenBrainz/Last.fm from
  config.json credentials, TIDAL tracks only. Navidrome has its own
  `/rest/scrobble` which feeds its play counts and its own Last.fm/LB relays.
- **Config** is config.json; scrobbler credentials are configured by editing
  it directly (scrobble.py:1-21 documents this convention). Settings shows
  read-only status rows for such integrations.
- **Subsonic auth**: every request carries `u` (user), `t` = md5(password +
  salt), `s` (salt), `v` (protocol, 1.16.1), `c` (client name), `f=json`.
  Responses wrap in `{"subsonic-response": {"status": "ok"|"failed", ...}}`.
  Relevant endpoints: `ping`, `search3`, `getAlbum`, `getArtist`,
  `getArtistInfo2`, `getCoverArt`, `stream`, `scrobble`, `getAlbumList2`.

## 2. Goals / non-goals

**Goals**
- Configure once in config.json: `navidromeUrl`, `navidromeUser`,
  `navidromePass`. No server → nothing changes anywhere.
- Navidrome results appear in the normal search, tagged; its albums and
  artists open as normal pages; its tracks queue, crossfade, resume and
  analyze (drop map → Pilgrimage) like TIDAL's.
- Plays scrobble to the Navidrome server (now-playing + submission), which
  also updates its play counts.
- Status and settings say whether the server is reachable.

**Non-goals (YAGNI)**
- No download/rip integration of any kind.
- No playlists/mixes/favourites sync in v1, no offline cache, no
  multi-server, no settings editor for the credentials (config.json is the
  convention), no Navidrome-only library section.

## 3. Approaches

**A. A Subsonic source in the daemon, merged into the existing routes
(chosen).** New `orpheusd/navidrome.py` (a `Navidrome` class mirroring
`YouTube`'s surface plus `search`/`album`/`artist`/`scrobble`), registered in
`Player.sources` under `"navidrome"`; `/search` merges its results; item
routes accept `?provider=navidrome`; the analysis gate allowlists it. Reuses
every existing pipe; the UI change is passing `provider` through two
navigations and a tag on rows.

**B. A separate "section 9½" Navidrome browser** like the video section.
Clean isolation, but duplicates search/album/artist UI that already exists,
and Navidrome tracks are music — they belong in the music pipes, not beside
them.

**C. Proxy Navidrome through the daemon as fake TIDAL ids.** No UI work at
all, but id collisions, wrong metadata semantics, and lies to the scrobbler.
Rejected.

## 4. Design (approach A)

1. **orpheusd/navidrome.py** — `class Navidrome`:
   - ctor takes `url, user, password` (stripped; empty → `available=False`).
   - `_params()` fresh salt per request; `_get(endpoint, **q)` →
     aiohttp GET `{url}/rest/{endpoint}` with auth params, raises
     `NavidromeError(message)` on `status != ok` or transport failure.
   - Entry mapping (all dicts carry `"provider": "navidrome"`):
     track → `{kind: "track", id, title, artist, artists: [..], album,
     albumId, duration, cover}` where `cover` is the authed `getCoverArt`
     URL; album → `{kind: "album", id, title, artist, artistId, year,
     tracks?: n, cover}`; artist → `{kind: "artist", id, name, cover}`.
   - `search(q)` → `search3` (counts 20/20/20) → `{tracks, albums, artists,
     playlists: []}`.
   - `album(id)` → `getAlbum` → `{album: <entry>, tracks: [..]}` matching
     the TIDAL album page shape used by `self.fetch`.
   - `artist(id)` → `getArtist` → `{artist: <entry>, albums: [..]}`.
   - `stream(id)` → `{"url": <authed /rest/stream?id=..&format=raw>,
     "quality": "LOSSLESS"-ish from the song's suffix/bitrate via `getSong`}`;
     `forget(id)` is a no-op (URLs are deterministic).
   - `ping()` → bool, cached briefly, for /status.
   - `scrobble(id, submission: bool)` → `/rest/scrobble`, fire-and-forget.
2. **Registration** (__main__.py): build from config at startup and on config
   change the same way scrobble reads its keys; when `available`, add to
   `self.sources["navidrome"]` and to the `/status` providers block
   (`navidrome: true` + `navidromeOk` from ping).
3. **Search** (__main__.py `search`): when Navidrome is available, run both
   searches concurrently and append Navidrome's tracks/albums/artists after
   TIDAL's in the same lists (entries are provider-tagged; TIDAL outage must
   not break Navidrome results and vice versa — each side degrades to empty).
   When TIDAL is signed out but Navidrome is configured, `/search` works with
   Navidrome alone (the `need_login` guard moves: Navidrome-only search is
   legal signed out).
4. **Item pages** (__main__.py `item`): `?provider=navidrome` on
   `/album/{id}` and `/artist/{id}` routes to `navidrome.album/artist`.
   Api.qml's page fetch appends the provider query when the navigated item
   carries one; Library row → `go({type, id, provider})` passes it through.
5. **Analysis gate** (analysis.py `skip_reason`): the `provider` skip becomes
   `if track.get("provider") not in (None, "", "navidrome")`. The worker
   already hands ffmpeg a URL; Navidrome's is stable for the analysis window.
6. **Scrobble**: where the player marks a track as now-playing/finished for
   scrobble.py, Navidrome-provided tracks call `navidrome.scrobble(id,
   submission)` instead of the LB/Last.fm path (the server relays onward if
   the user configured it there). Locate the existing now-playing/queue
   hook in scrobble.py/player and branch on provider.
7. **UI**:
   - Search rows: provider-tagged rows show a dim `nd` chip (same mechanism
     as the HR quality chip in track rows), so mixed results read.
   - Row activation passes `provider` into `go(...)` for albums/artists and
     into `/enqueue` for tracks (enqueue already forwards the track dict).
   - SettingsPane "connections" area: one note row — "navidrome ·
     <host> · reachable|unreachable" when configured (read from status).
8. **Config**: the three keys are read by the daemon only; document them in
   README's More-than-TIDAL section.

## 5. Testing

- `tests/test_navidrome.py` with an aiohttp fake Subsonic server (the
  TestClient pattern from tests/test_shaders.py): auth params present and
  token = md5(pass+salt); search3 mapping to tagged entries; album/artist
  shapes; stream URL carries auth and the id; failed status raises; scrobble
  hits `/rest/scrobble` with `submission`.
- Analysis gate: `provider: "navidrome"` is not skipped; `provider:
  "youtube"` still is (extend the existing analysis tests).
- Search merge: both sides answer → merged and tagged; one side failing →
  the other's results still come back.
- Live check: point at the user's Navidrome if reachable; else the fake.

## 6. Open points settled by convention

- Credentials in config.json (matches the scrobbler convention) — a settings
  editor can come later.
- The password sits in config.json like other keys; Subsonic token auth at
  least keeps it off the wire.
- `playlists` from Navidrome: v2.
