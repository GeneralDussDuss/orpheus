"""The user's config.json, read by the daemon.

The player window owns ~/.config/orpheus/config.json and writes it on every
settings change; the daemon only reads the keys that are about playback
(endless, crossfade, remote, scrobbling credentials). It is re-read when its
modification time moves, checked at most once a second, so a change in the
settings page reaches the daemon without any extra API.

ORPHEUS_CONFIG points at another file (tests); otherwise it follows the
desktop app's rule: ORPHEUS_HOME, then HOME, then the user's home.
"""

import json
import logging
import os
import time
from pathlib import Path

log = logging.getLogger("orpheus.config")

DEFAULTS = {
    "endless": True,         # keep going with TIDAL radio when the queue runs out
    "crossfade": 0,          # seconds, 0 = gapless (and never within an album)
    "remote": "off",         # off | lan: the phone remote's LAN listener
    "remotePort": 47838,
    "remoteHost": "",        # "" = the LAN address of the default route
    "listenbrainzToken": "",
    "listenbrainzUrl": "",   # "" = https://api.listenbrainz.org (tests point it elsewhere)
    "lastfmKey": "",
    "lastfmSecret": "",
    "lastfmUrl": "",         # "" = https://ws.audioscrobbler.com/2.0/
}


def config_path() -> Path:
    if os.environ.get("ORPHEUS_CONFIG"):
        return Path(os.environ["ORPHEUS_CONFIG"])
    home = os.environ.get("ORPHEUS_HOME") or os.environ.get("HOME") or str(Path.home())
    return Path(home) / ".config" / "orpheus" / "config.json"


class Config:
    def __init__(self, path: Path | None = None):
        self.path = path or config_path()
        self._data: dict = {}
        self._mtime = None
        self._checked = 0.0
        self.version = 0          # bumps when the file's content changes
        self.refresh(force=True)

    def refresh(self, force: bool = False) -> bool:
        now = time.monotonic()
        if not force and now - self._checked < 1.0:
            return False
        self._checked = now
        try:
            mtime = self.path.stat().st_mtime
        except OSError:
            mtime = None
        if mtime == self._mtime and not force:
            return False
        self._mtime = mtime
        data = {}
        if mtime is not None:
            try:
                data = json.loads(self.path.read_text(encoding="utf-8")) or {}
            except Exception as e:
                # Half-written by the UI, or hand-edited badly: keep the last good one.
                log.debug("config.json unreadable (%s); keeping the last copy", e)
                return False
        if not isinstance(data, dict):
            data = {}
        if data != self._data:
            self._data = data
            self.version += 1
            return True
        return False

    def get(self, key: str, default=None):
        self.refresh()
        if key in self._data:
            return self._data[key]
        return DEFAULTS.get(key, default) if default is None else default

    # typed readers, forgiving about what a hand edit might put there

    @property
    def endless(self) -> bool:
        return self.get("endless") is not False

    @property
    def crossfade(self) -> float:
        try:
            return max(0.0, min(12.0, float(self.get("crossfade") or 0)))
        except (TypeError, ValueError):
            return 0.0

    @property
    def remote(self) -> str:
        return "lan" if self.get("remote") == "lan" else "off"

    def text(self, key: str) -> str:
        v = self.get(key)
        return v.strip() if isinstance(v, str) else ""
