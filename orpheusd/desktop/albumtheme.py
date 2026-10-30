"""The "album" theme: a palette pulled from the cover of whatever is playing.

The cover is fetched once per track, shrunk to a thumbnail, and its pixels are
binned by hue, weighted toward vivid mid-tones. The heaviest hue becomes the
accent, the runner-up the second visualizer colour, and the background and text
are near-black and near-white tinted with the accent's hue, so any cover reads.
themegen then fills in the rest exactly as it does for the builder.
"""
from __future__ import annotations

import colorsys

from PySide6.QtCore import QObject, QUrl, Qt
from PySide6.QtGui import QImage
from PySide6.QtNetwork import QNetworkAccessManager, QNetworkRequest

from . import themegen

NAME = "album"


def _hex_hls(h, l, s) -> str:
    return themegen._hex(colorsys.hls_to_rgb(h % 1.0, l, s))


def extract(img: QImage) -> dict | None:
    """A full palette from a cover, or None for an unreadable image."""
    if img.isNull():
        return None
    img = img.scaled(48, 48, Qt.AspectRatioMode.IgnoreAspectRatio, Qt.TransformationMode.SmoothTransformation)
    bins = [[0.0, 0.0, 0.0] for _ in range(24)]  # weight, weighted hue, weighted saturation
    for y in range(img.height()):
        for x in range(img.width()):
            c = img.pixelColor(x, y)
            h, l, s = colorsys.rgb_to_hls(c.redF(), c.greenF(), c.blueF())
            w = s * (1 - abs(2 * l - 1))  # vivid mid-tones count, greys and blown-out pixels don't
            b = bins[int(h * 24) % 24]
            b[0] += w
            b[1] += w * h
            b[2] += w * s
    ranked = sorted(range(24), key=lambda i: bins[i][0], reverse=True)
    top = bins[ranked[0]]
    if top[0] < 1.5:  # a black-and-white cover: keep it monochrome with a cool accent
        hue, sat, hue2 = 0.6, 0.15, 0.6
    else:
        hue, sat = top[1] / top[0], min(0.95, max(0.55, top[2] / top[0] * 1.3))
        second = next((i for i in ranked[1:] if min(abs(i - ranked[0]), 24 - abs(i - ranked[0])) >= 3
                       and bins[i][0] > top[0] * 0.15), None)
        hue2 = bins[second][1] / bins[second][0] if second is not None else hue + 0.12
    accent = _hex_hls(hue, 0.64, sat)
    bg = _hex_hls(hue, 0.075, min(0.45, sat * 0.5))
    fg = _hex_hls(hue, 0.88, min(0.25, sat * 0.3))
    return themegen.palette(bg, fg, accent, magenta=_hex_hls(hue2, 0.64, sat), bright_magenta=_hex_hls(hue2, 0.72, sat))


class AlbumTheme(QObject):
    """Follows the playing track's cover and hands Color a palette for it."""

    def __init__(self, color, parent=None):
        super().__init__(parent)
        self.color = color          # the Color singleton
        self.palette: dict | None = None
        self._url = ""
        self._net = QNetworkAccessManager(self)

    def track_art(self, url: str):
        """Called on every status poll; fetches only when the cover changes."""
        if not url or url == self._url:
            return
        self._url = url
        reply = self._net.get(QNetworkRequest(QUrl(url)))
        reply.finished.connect(lambda: self._done(reply, url))

    def _done(self, reply, url):
        data = bytes(reply.readAll().data())
        reply.deleteLater()
        if url != self._url:
            return  # a newer track's cover is already on its way
        p = extract(QImage.fromData(data))
        if p:
            self.palette = p
            if self.color.property("name") == NAME:
                self.color.apply_album(p)
