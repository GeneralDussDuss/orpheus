"""The theme builder: three colours in, a whole Omarchy-style theme out.

Pick a background, a text colour and an accent (or roll the dice), and themegen
fills in the other twenty-odd keys. Any of the eight hues can be overridden by
clicking it; right-click hands it back to the generator. The whole app follows
along live, and Save writes ~/.config/orpheus/themes/<name>.toml, which then sits
in the tray's Theme menu under Yours like any other theme.
"""
from __future__ import annotations

import re

from PySide6.QtCore import Qt
from PySide6.QtGui import QColor
from PySide6.QtWidgets import (QCheckBox, QColorDialog, QDialog, QGridLayout, QHBoxLayout,
                               QLabel, QLineEdit, QMessageBox, QPushButton, QVBoxLayout)

from . import themegen
from .shims import THEME, theme_names, user_themes_dir

CORE = [("background", "Background"), ("foreground", "Text"), ("accent", "Accent")]


def _slug(name: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")


class Swatch(QPushButton):
    def __init__(self, label: str, on_pick, on_reset=None, big=False):
        super().__init__()
        self.label, self.on_pick, self.on_reset = label, on_pick, on_reset
        self.setFixedSize(*((132, 64) if big else (66, 48)))
        self.setCursor(Qt.CursorShape.PointingHandCursor)
        self.clicked.connect(self._pick)
        self.setContextMenuPolicy(Qt.ContextMenuPolicy.CustomContextMenu)
        self.customContextMenuRequested.connect(lambda _: on_reset and on_reset())
        self.color = "#000000"

    def show_color(self, color: str, pinned: bool = False):
        self.color = color
        text = "#ffffff" if themegen.luminance(color) < 0.5 else "#000000"
        self.setText(f"{self.label}{' •' if pinned else ''}\n{color}")
        self.setStyleSheet(f"QPushButton {{ background: {color}; color: {text}; border: 1px solid #00000040;"
                           f" border-radius: 6px; font-size: 11px; }}")

    def _pick(self):
        c = QColorDialog.getColor(QColor(self.color), self, self.label)
        if c.isValid():
            self.on_pick(c.name())


class ThemeBuilder(QDialog):
    def __init__(self, parent=None):
        super().__init__(parent)
        self.setWindowTitle("Orpheus · theme builder")
        self.setMinimumWidth(640)
        live = THEME[0] if THEME else None
        self._was = live.property("name") if live else ""
        start = live.current_palette() if live else {}
        self.core = {k: start.get(k) or d for k, d in
                     (("background", "#0b0d12"), ("foreground", "#d7dbe6"), ("accent", "#5b8cff"))}
        self.pinned: dict[str, str] = {}
        self.palette: dict = {}

        lay = QVBoxLayout(self)
        top = QHBoxLayout()
        top.addWidget(QLabel("Name"))
        self.name = QLineEdit(placeholderText="my-theme")
        top.addWidget(self.name, 1)
        lay.addLayout(top)

        core_row = QHBoxLayout()
        self.core_sw = {}
        for key, label in CORE:
            sw = Swatch(label, lambda c, k=key: self._set_core(k, c), big=True)
            self.core_sw[key] = sw
            core_row.addWidget(sw)
        core_row.addStretch(1)
        side = QVBoxLayout()
        roll = QPushButton("Randomize")
        roll.clicked.connect(self._roll)
        self.light = QCheckBox("light")
        swap = QPushButton("Flip light/dark")
        swap.clicked.connect(self._flip)
        side.addWidget(roll)
        side.addWidget(self.light)
        side.addWidget(swap)
        core_row.addLayout(side)
        lay.addLayout(core_row)

        lay.addWidget(QLabel("Hues: click to set one yourself, right-click to give it back to the generator"))
        grid = QGridLayout()
        self.hue_sw = {}
        for i, h in enumerate(themegen.HUES):
            sw = Swatch(h, lambda c, k=h: self._pin(k, c), lambda k=h: self._unpin(k))
            self.hue_sw[h] = sw
            grid.addWidget(sw, i // 4, i % 4)
        lay.addLayout(grid)

        self.sample = QLabel()
        self.sample.setMinimumHeight(70)
        self.sample.setTextFormat(Qt.TextFormat.RichText)
        lay.addWidget(self.sample)

        buttons = QHBoxLayout()
        buttons.addStretch(1)
        cancel = QPushButton("Cancel")
        cancel.clicked.connect(self.reject)
        save = QPushButton("Save theme")
        save.setDefault(True)
        save.clicked.connect(self._save)
        buttons.addWidget(cancel)
        buttons.addWidget(save)
        lay.addLayout(buttons)
        self._refresh()

    # ---- editing ------------------------------------------------------------
    def _set_core(self, key, color):
        self.core[key] = color
        self._refresh()

    def _pin(self, key, color):
        self.pinned[key] = color
        self._refresh()

    def _unpin(self, key):
        self.pinned.pop(key, None)
        self._refresh()

    def _roll(self):
        bg, fg, acc = themegen.random_seed(self.light.isChecked())
        self.core = {"background": bg, "foreground": fg, "accent": acc}
        self.pinned.clear()
        self._refresh()

    def _flip(self):
        self.core["background"], self.core["foreground"] = self.core["foreground"], self.core["background"]
        self._refresh()

    def _refresh(self):
        c = self.core
        self.palette = themegen.palette(c["background"], c["foreground"], c["accent"], **self.pinned)
        self.light.setChecked(self.palette["mode"] == "light")
        for k, sw in self.core_sw.items():
            sw.show_color(c[k])
        for k, sw in self.hue_sw.items():
            sw.show_color(self.palette[k], k in self.pinned)
        p = self.palette
        dots = "".join(f'<span style="color:{p[h]}">■</span>' for h in themegen.HUES)
        self.sample.setText(
            f'<div style="background:{p["background"]}; padding:10px">'
            f'<span style="color:{p["accent"]}">▶ now playing</span>'
            f'<span style="color:{p["foreground"]}">  Ship Is Not A Child · OTT</span><br>'
            f'<span style="color:{p["dark_foreground"]}">vol ▰▰▰▰▰▱▱▱  shuf  ↻ off  </span>{dots}</div>')
        self.sample.setStyleSheet(f"background:{p['background']}; border-radius:6px;")
        if THEME:
            THEME[0].preview(self.palette)

    # ---- finishing ----------------------------------------------------------
    def _save(self):
        slug = _slug(self.name.text())
        if not slug:
            QMessageBox.information(self, "Name it", "Give the theme a name first.")
            return
        dest = user_themes_dir() / f"{slug}.toml"
        if dest.exists() or slug in theme_names():
            ok = QMessageBox.question(self, "Replace?", f"A theme called {slug} already exists. Replace it?")
            if ok != QMessageBox.StandardButton.Yes:
                return
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(themegen.to_toml(self.palette, f"Made in the Orpheus theme builder: {self.name.text()}"),
                        encoding="utf-8")
        if THEME:
            THEME[0].set_theme(slug)
        self.accept()

    def reject(self):
        if THEME:
            THEME[0].set_theme(self._was, save=False)  # put the real theme back
        super().reject()


_OPEN: list = []


def open_builder():
    """One builder at a time; a second request raises the open one."""
    if _OPEN and _OPEN[0].isVisible():
        _OPEN[0].raise_()
        _OPEN[0].activateWindow()
        return
    d = ThemeBuilder()
    d.setAttribute(Qt.WidgetAttribute.WA_DeleteOnClose)
    d.finished.connect(lambda _: _OPEN.clear())
    _OPEN[:] = [d]
    d.show()
