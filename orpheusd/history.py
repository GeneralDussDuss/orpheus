"""Listening history: every play in SQLite, and the stats read back from it.

A play is a row from the moment a track starts until the next one does. The
row is written when it starts and its listened time is brought up to date
every few seconds, so a daemon killed with TerminateProcess (which is how the
desktop app stops it) loses a few seconds, not the play; rows left open by a
kill are closed on the next start.

`listened` is time actually heard (paused time and seeks do not count), which
is what the stats and the scrobble rules want; position would let one seek to
the end pass for a full listen.
"""

import datetime as dt
import json
import logging
import sqlite3
import threading
import time
from collections import Counter, defaultdict
from pathlib import Path

log = logging.getLogger("orpheus.history")

SCHEMA = """
CREATE TABLE IF NOT EXISTS plays (
  id INTEGER PRIMARY KEY,
  started REAL NOT NULL,          -- unix seconds
  ended REAL,                     -- NULL while it plays
  track_id TEXT NOT NULL,
  provider TEXT NOT NULL DEFAULT 'tidal',
  title TEXT NOT NULL DEFAULT '',
  artists TEXT NOT NULL DEFAULT '[]',   -- JSON list
  artist_id TEXT NOT NULL DEFAULT '',
  album TEXT NOT NULL DEFAULT '',
  album_id TEXT NOT NULL DEFAULT '',
  isrc TEXT NOT NULL DEFAULT '',
  duration REAL NOT NULL DEFAULT 0,
  listened REAL NOT NULL DEFAULT 0,
  skipped INTEGER NOT NULL DEFAULT 0,
  context TEXT NOT NULL DEFAULT '{}'    -- JSON: what it was played from
);
CREATE INDEX IF NOT EXISTS plays_started ON plays(started);
CREATE INDEX IF NOT EXISTS plays_track ON plays(track_id);
CREATE TABLE IF NOT EXISTS scrobbles (
  id INTEGER PRIMARY KEY,
  service TEXT NOT NULL,          -- listenbrainz | lastfm
  listened_at INTEGER NOT NULL,
  payload TEXT NOT NULL,          -- the track, as JSON
  tries INTEGER NOT NULL DEFAULT 0,
  next_try REAL NOT NULL DEFAULT 0,
  error TEXT NOT NULL DEFAULT ''
);
"""


def scrobblable(duration: float, listened: float) -> bool:
    """The standard rule (Last.fm's, which ListenBrainz follows): the track is
    longer than 30 s, and it was heard for half its length or 4 minutes,
    whichever comes first."""
    return duration > 30 and listened >= min(duration / 2, 240)


class History:
    def __init__(self, state_dir: Path):
        self.path = state_dir / "history.sqlite"
        self._lock = threading.Lock()
        self._db = sqlite3.connect(self.path, check_same_thread=False, isolation_level=None)
        self._db.execute("PRAGMA journal_mode=WAL")
        self._db.executescript(SCHEMA)

    def close(self):
        with self._lock:
            self._db.close()

    def _x(self, sql: str, args=()):
        with self._lock:
            return self._db.execute(sql, args)

    def _rows(self, sql: str, args=()) -> list:
        with self._lock:
            return self._db.execute(sql, args).fetchall()

    # ---- plays -----------------------------------------------------------------

    def begin(self, track: dict, context: dict, started: float) -> int:
        cur = self._x(
            "INSERT INTO plays (started, track_id, provider, title, artists, artist_id, album, album_id,"
            " isrc, duration, context) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
            (started, str(track.get("id", "")), track.get("provider") or "tidal",
             track.get("title") or "", json.dumps(list(track.get("artists") or [])),
             str(track.get("artistId") or ""), track.get("album") or "", str(track.get("albumId") or ""),
             track.get("isrc") or "", float(track.get("duration") or 0),
             json.dumps({k: (context or {}).get(k) for k in ("kind", "id", "title")} | (
                 {"radio": track["radio"].get("from")} if isinstance(track.get("radio"), dict) else {}))))
        return cur.lastrowid

    def update(self, row: int, listened: float, duration: float):
        self._x("UPDATE plays SET listened=?, duration=CASE WHEN ?>0 THEN ? ELSE duration END WHERE id=?",
                (round(listened, 1), duration, round(duration, 1), row))

    def finish(self, row: int, listened: float, duration: float, skipped: bool, ended: float):
        self._x("UPDATE plays SET listened=?, duration=CASE WHEN ?>0 THEN ? ELSE duration END,"
                " skipped=?, ended=? WHERE id=?",
                (round(listened, 1), duration, round(duration, 1), int(skipped), ended, row))

    def close_dangling(self) -> list[dict]:
        """Close plays a killed daemon left open; returns the ones worth a scrobble."""
        rows = self._rows("SELECT id, started, track_id, provider, title, artists, album, album_id, isrc,"
                          " duration, listened FROM plays WHERE ended IS NULL")
        out = []
        for (rid, started, tid, prov, title, artists, album, album_id, isrc, duration, listened) in rows:
            skipped = listened < duration * 0.5
            self._x("UPDATE plays SET ended=?, skipped=? WHERE id=?", (started + listened, int(skipped), rid))
            if listened > 0 and scrobblable(duration, listened):
                out.append({"started": started, "track": {
                    "id": tid, "provider": prov, "title": title, "artists": json.loads(artists or "[]"),
                    "album": album, "albumId": album_id, "isrc": isrc, "duration": duration}})
        return out

    def recent_ids(self, hours: float = 72, limit: int = 400) -> set[str]:
        """Track ids heard lately, so endless play does not bring them straight back."""
        since = time.time() - hours * 3600
        return {r[0] for r in self._rows(
            "SELECT track_id FROM plays WHERE started >= ? ORDER BY started DESC LIMIT ?", (since, limit))}

    # ---- the scrobble queue ------------------------------------------------------

    def queue_scrobble(self, service: str, listened_at: int, track: dict):
        self._x("INSERT INTO scrobbles (service, listened_at, payload) VALUES (?,?,?)",
                (service, int(listened_at), json.dumps(track)))

    def due_scrobbles(self, service: str, limit: int = 50) -> list[tuple[int, int, dict]]:
        rows = self._rows("SELECT id, listened_at, payload FROM scrobbles WHERE service=? AND next_try<=?"
                          " ORDER BY listened_at LIMIT ?", (service, time.time(), limit))
        return [(r[0], r[1], json.loads(r[2])) for r in rows]

    def scrobbled(self, ids: list[int]):
        if ids:
            self._x(f"DELETE FROM scrobbles WHERE id IN ({','.join('?' * len(ids))})", ids)

    def scrobble_failed(self, ids: list[int], error: str, drop: bool = False):
        """Back off: 1 min, doubling to 6 h. A rejected scrobble (bad data, not a
        network problem) is dropped instead of retried forever."""
        if not ids:
            return
        if drop:
            return self.scrobbled(ids)
        q = ",".join("?" * len(ids))
        self._x(f"UPDATE scrobbles SET tries=tries+1, error=?,"
                f" next_try=? + MIN(21600, 60 * (1 << MIN(tries, 9))) WHERE id IN ({q})",
                [error[:300], time.time(), *ids])

    def pending(self) -> dict:
        return {s: n for s, n in self._rows("SELECT service, COUNT(*) FROM scrobbles GROUP BY service")}

    # ---- stats -----------------------------------------------------------------

    def stats(self, range_: str = "week", now: float | None = None, top: int = 10) -> dict:
        now = now or time.time()
        today = dt.datetime.fromtimestamp(now).date()
        if range_ == "week":
            start_day = today - dt.timedelta(days=6)
        elif range_ == "month":
            start_day = today - dt.timedelta(days=29)
        elif range_ == "year":
            start_day = today - dt.timedelta(days=364)
        elif range_ == "wrapped":
            start_day = today.replace(day=1)
        else:
            range_, start_day = "all", None
        since = time.mktime(start_day.timetuple()) if start_day else 0.0
        rows = self._rows("SELECT started, track_id, provider, title, artists, album, album_id, duration,"
                          " listened, skipped FROM plays WHERE started >= ? AND listened >= 1 ORDER BY started",
                          (since,))
        plays = [dict(zip(("started", "id", "provider", "title", "artists", "album", "albumId", "duration",
                           "listened", "skipped"), r)) for r in rows]
        for p in plays:
            p["artists"] = json.loads(p["artists"] or "[]")
        out = _summarise(plays, top)
        out["range"] = range_
        out["from"] = since or (plays[0]["started"] if plays else now)
        out["to"] = now
        out["series"] = _series(plays, range_, start_day, today)
        out["streaks"] = self._streaks(today, plays)
        if range_ == "wrapped":
            out["wrapped"] = self._wrapped(plays, since, today)
        return out

    def _streaks(self, today: dt.date, ranged: list[dict]) -> dict:
        """Days with at least one real listen (30 s, or the whole of a shorter
        track) in a row. `current` runs up to today, or yesterday when today
        has nothing yet; `longest` is within the range asked for."""
        days_all = {dt.date.fromtimestamp(r[0]) for r in self._rows(
            "SELECT started FROM plays WHERE listened >= 30 OR (listened >= duration * 0.9 AND duration > 0)")}
        cur, d = 0, today if today in days_all else today - dt.timedelta(days=1)
        while d in days_all:
            cur += 1
            d -= dt.timedelta(days=1)
        days = sorted({dt.date.fromtimestamp(p["started"]) for p in ranged
                       if p["listened"] >= 30 or (p["duration"] and p["listened"] >= p["duration"] * 0.9)})
        best = run = 0
        prev = None
        best_end = None
        for d in days:
            run = run + 1 if prev and (d - prev).days == 1 else 1
            if run > best:
                best, best_end = run, d
            prev = d
        return {"current": cur, "longest": best,
                "longestEnd": best_end.isoformat() if best_end else "", "days": len(days)}

    def _wrapped(self, plays: list[dict], since: float, today: dt.date) -> dict:
        before = {r[0] for r in self._rows("SELECT artists FROM plays WHERE started < ? AND listened >= 30", (since,))}
        known = set()
        for a in before:
            known.update(json.loads(a or "[]"))
        new_artists = Counter()
        by_day = defaultdict(float)
        by_hour = defaultdict(float)
        replays = Counter()
        for p in plays:
            day = dt.date.fromtimestamp(p["started"])
            by_day[day] += p["listened"] / 60
            by_hour[dt.datetime.fromtimestamp(p["started"]).hour] += p["listened"] / 60
            if not p["skipped"]:
                replays[(day, p["id"])] += 1
            for a in p["artists"]:
                if a not in known:
                    new_artists[a] += p["listened"] / 60
        top_day = max(by_day.items(), key=lambda kv: kv[1]) if by_day else None
        top_hour = max(by_hour.items(), key=lambda kv: kv[1]) if by_hour else None
        (rday, rid), rn = replays.most_common(1)[0] if replays else ((None, None), 0)
        replay_title = next((p for p in plays if p["id"] == rid), None)
        first = plays[0] if plays else None
        return {
            "month": today.strftime("%B %Y"),
            "topDay": {"date": top_day[0].isoformat(), "minutes": round(top_day[1])} if top_day else None,
            "topHour": {"hour": top_hour[0], "minutes": round(top_hour[1])} if top_hour else None,
            "newArtists": [{"name": a, "minutes": round(m, 1)} for a, m in new_artists.most_common(5)],
            "newArtistCount": len(new_artists),
            "onRepeat": {"title": replay_title["title"], "artists": replay_title["artists"], "plays": rn,
                         "date": rday.isoformat()} if replay_title and rn > 1 else None,
            "first": {"title": first["title"], "artists": first["artists"],
                      "at": first["started"]} if first else None,
        }


def _summarise(plays: list[dict], top: int) -> dict:
    tracks, artists, albums = {}, {}, {}
    heat = [[0.0] * 24 for _ in range(7)]
    minutes = skips = 0.0
    for p in plays:
        m = p["listened"] / 60
        minutes += m
        skips += p["skipped"]
        t = dt.datetime.fromtimestamp(p["started"])
        heat[t.weekday()][t.hour] += m
        key = (p["provider"], p["id"])
        e = tracks.setdefault(key, {"id": p["id"], "provider": p["provider"], "title": p["title"],
                                    "artists": p["artists"], "album": p["album"], "plays": 0, "minutes": 0.0,
                                    "skips": 0})
        e["minutes"] += m
        if p["skipped"]:
            e["skips"] += 1
        else:
            e["plays"] += 1
        for a in p["artists"][:3]:
            ae = artists.setdefault(a, {"name": a, "plays": 0, "minutes": 0.0})
            ae["minutes"] += m
            ae["plays"] += 0 if p["skipped"] else 1
        if p["album"]:
            ke = p["albumId"] or p["album"]
            al = albums.setdefault(ke, {"id": p["albumId"], "title": p["album"],
                                        "artists": p["artists"][:1], "plays": 0, "minutes": 0.0})
            al["minutes"] += m
            al["plays"] += 0 if p["skipped"] else 1

    def best(d):
        return sorted(d.values(), key=lambda e: (-e["plays"], -e["minutes"]))[:top]

    for coll in (tracks, artists, albums):
        for e in coll.values():
            e["minutes"] = round(e["minutes"], 1)
    return {
        "minutes": round(minutes, 1),
        "plays": len(plays) - int(skips),
        "skips": int(skips),
        "skipRate": round(skips / len(plays), 3) if plays else 0,
        "distinct": {"tracks": len(tracks), "artists": len(artists), "albums": len(albums)},
        "tracks": best(tracks),
        "artists": best(artists),
        "albums": best(albums),
        # minutes, [weekday 0=Monday][hour 0-23], local time
        "heatmap": [[round(v, 1) for v in row] for row in heat],
    }


def _series(plays: list[dict], range_: str, start_day, today: dt.date) -> list[dict]:
    """Minutes per day (week, month, wrapped) or per month (year, all)."""
    if range_ in ("week", "month", "wrapped"):
        days = (today - start_day).days + 1
        buckets = {start_day + dt.timedelta(days=i): 0.0 for i in range(days)}
        for p in plays:
            d = dt.date.fromtimestamp(p["started"])
            if d in buckets:
                buckets[d] += p["listened"] / 60
        return [{"label": d.strftime("%a" if range_ == "week" else "%d"), "date": d.isoformat(),
                 "minutes": round(m, 1)} for d, m in buckets.items()]
    first = start_day or (dt.date.fromtimestamp(plays[0]["started"]) if plays else today)
    months = []
    y, m = first.year, first.month
    while (y, m) <= (today.year, today.month):
        months.append((y, m))
        y, m = (y + 1, 1) if m == 12 else (y, m + 1)
    months = months[-24:]
    buckets = {k: 0.0 for k in months}
    for p in plays:
        d = dt.date.fromtimestamp(p["started"])
        if (d.year, d.month) in buckets:
            buckets[(d.year, d.month)] += p["listened"] / 60
    return [{"label": dt.date(y, m, 1).strftime("%b"), "date": f"{y:04d}-{m:02d}", "minutes": round(v, 1)}
            for (y, m), v in buckets.items()]


class Tracker:
    """Turns the player's state, sampled once a second, into plays.

    `serial` is the player's count of track starts, so the same track played
    twice (repeat one, or jumping back to it) is two plays."""

    SAVE_EVERY = 10.0

    def __init__(self, history: History, on_now_playing=None, on_scrobble=None):
        self.history = history
        self.on_now_playing = on_now_playing
        self.on_scrobble = on_scrobble
        self.serial = None
        self.track = None
        self.row = None
        self.started = 0.0
        self.listened = 0.0
        self.duration = 0.0
        self.last_pos = 0.0
        self._last = time.monotonic()
        self._saved = 0.0
        self._announced = False

    def tick(self, player, end_slack: float = 0.0):
        now = time.monotonic()
        dt_ = min(2.0, now - self._last)
        self._last = now
        if player.serial != self.serial:
            self.finish(end_slack)
            self.serial = player.serial
            cur = player.current
            if cur:
                self.track = dict(cur)
                self.started = time.time()
                self.listened = 0.0
                self.duration = float(player.duration or cur.get("duration") or 0)
                self.last_pos = player.position
                self.row = None
                self._announced = False
            return
        if self.track is None:
            return
        if player.playing:
            self.listened += dt_
            self.last_pos = player.position
            if player.duration:
                self.duration = float(player.duration)
            if self.row is None and self.listened >= 1:
                # Only a track that actually played becomes a row.
                self.row = self.history.begin(self.track, player.context, self.started)
                self._saved = now
            if not self._announced and self.listened >= 2:
                self._announced = True
                if self.on_now_playing:
                    self.on_now_playing(self.track)
            if self.row is not None and now - self._saved >= self.SAVE_EVERY:
                self._saved = now
                self.history.update(self.row, self.listened, self.duration)

    def finish(self, end_slack: float = 0.0):
        """Close the play in progress. A track counts as skipped when it was left
        before its end (allowing for a crossfade's early start) with less than
        half of it heard."""
        if self.track is None or self.row is None:
            self.track = None
            return
        ended = self.duration > 0 and self.last_pos >= self.duration - max(15.0, end_slack + 5)
        skipped = not ended and self.listened < self.duration * 0.5
        self.history.finish(self.row, self.listened, self.duration, skipped, time.time())
        if scrobblable(self.duration, self.listened) and self.on_scrobble:
            self.on_scrobble(self.track, self.started)
        self.track, self.row = None, None
