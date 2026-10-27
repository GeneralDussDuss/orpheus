"""SoundCloud, through the same door as YouTube.

What TIDAL does not carry lives here: DJ sets, Boiler Rooms, bootlegs, edits.
yt-dlp already speaks SoundCloud, so this is the YouTube source with another
search prefix and another row shape; the player, queue, equaliser and
visualiser never learn the difference. Audio only - there is nothing to watch.
"""

from __future__ import annotations

import re

from .youtube import YouTube, thumbnail

# A track permalink is two path segments; a profile (one) or a set is a list,
# which a search row cannot stand for.
_TRACK = re.compile(r"^https?://(?:www\.|m\.)?soundcloud\.com/[^/?#]+/(?!sets/)[^/?#]+")


class SoundCloud(YouTube):
    name = "soundcloud"
    SEARCH = "scsearch"
    SEARCH_ARGS = []

    def link(self, text: str) -> str | None:
        m = _TRACK.match((text or "").strip())
        return m.group(0) if m else None

    def page(self, item_id: str) -> str:
        # The numeric id resolves on its own, so a row - or a queue restored
        # from resume.json - never needs the permalink to play.
        return "https://api.soundcloud.com/tracks/" + item_id

    @staticmethod
    def _entry(e: dict) -> dict:
        return {
            "kind": "track",
            "provider": "soundcloud",
            "id": str(e.get("id") or ""),
            "title": e.get("title") or "untitled",
            "artists": [e["uploader"]] if e.get("uploader") else [],
            "album": "",
            "duration": int(e.get("duration") or 0),
            "art": thumbnail(e),
            "views": int(e.get("view_count") or 0),
            # unlike YouTube's, a real upload time, not an approximate age
            "published": int(e.get("timestamp") or 0),
            "live": False,
            "url": e.get("webpage_url") or "",
        }
