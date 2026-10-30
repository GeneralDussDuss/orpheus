"""The theme builder: three colours in, a whole Omarchy-style theme out.

Pick a background, a text colour and an accent (or roll the dice), and themegen
fills in the other twenty-odd keys. Any of the eight hues can be overridden by
clicking it; right-click hands it back to the generator. The whole app follows
along live, and save writes ~/.config/orpheus/themes/<name>.toml, which then sits
in the tray's Theme menu under Yours like any other theme.

It is a widgets dialog, drawn in the player's own terms: one monospace face,
lowercase labels, square 1px boxes, ╱╱ section rules, and the colours of the
theme being built, so the dialog is its own preview. Keys: r roll, f flip
light/dark, ⏎ save, esc cancel.
"""
from __future__ import annotations

import re

from PySide6.QtCore import Qt
from PySide6.QtGui import QColor, QFont, QKeySequence, QShortcut
from PySide6.QtWidgets import (QColorDialog, QDialog, QGridLayout, QHBoxLayout,
                               QLabel, QLineEdit, QMessageBox, QPushButton, QVBoxLayout)

from . import themegen
from .shims import THEME, theme_names, user_themes_dir

CORE = [("background", "background"), ("foreground", "text"), ("accent", "accent")]


def _slug(name: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")


def _mono() -> str:
    try:
        from .shims import _mono_family
        return _mono_family()
    except Exception:
        return "Consolas"


def _ensure(fg: str, bg: str, ratio: float) -> str:
    """`fg` nudged toward the far end of `bg` until it reads at `ratio`:1, the
    same rule as Tui.ensure, so an accent stays legible as text."""
    def lum(c):
        h = c.lstrip("#")
        ch = [int(h[i:i + 2], 16) / 255 for i in (0, 2, 4)]
        ch = [v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4 for v in ch]
        return 0.2126 * ch[0] + 0.7152 * ch[1] + 0.0722 * ch[2]

    def contrast(a, b):
        la, lb = lum(a), lum(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    far = "#000000" if themegen.luminance(bg) > 0.5 else "#ffffff"
    c, t = fg, 0.0
    while contrast(c, bg) < ratio and t < 1.0:
        t += 0.05
        c = themegen.mix(fg, far, t)
    return c


def _rule(title: str, accent: str, line: str, width: int = 120) -> str:
    """╱╱ title ─────── as rich text, the section header every pane uses."""
    return (f'<span style="color:{accent}">╱╱</span> {title} '
            f'<span style="color:{line}">{"─" * width}</span>')


class Swatch(QPushButton):
    """A square chip of the colour, its name and hex inside it. Click picks,
    right-click hands it back (hues only)."""

    def __init__(self, label: str, on_pick, on_reset=None, big=False):
        super().__init__()
        self.label, self.on_pick, self.on_reset = label, on_pick, on_reset
        self.setFixedSize(*((128, 60) if big else (128, 44)))
        self.setAutoDefault(False)   # ⏎ saves the theme; it must never open a colour picker
        self.setCursor(Qt.CursorShape.PointingHandCursor)
        self.clicked.connect(self._pick)
        self.setContextMenuPolicy(Qt.ContextMenuPolicy.CustomContextMenu)
        self.customContextMenuRequested.connect(lambda _: on_reset and on_reset())
        self.color = "#000000"
        self.line = "#444444"
        self.setToolTip(f"{label} · click to pick" + (" · right-click: back to the generator" if on_reset else ""))

    def show_color(self, color: str, pinned: bool = False, line: str = "#444444", accent: str = "#888888"):
        self.color = color
        text = "#ffffff" if themegen.luminance(color) < 0.5 else "#000000"
        self.setText(f"{self.label}{' •' if pinned else ''}\n{color}")
        self.setStyleSheet(f"QPushButton {{ background: {color}; color: {text}; border: 1px solid {line};"
                           f" border-radius: 0px; text-align: left; padding: 4px 6px; }}"
                           f"QPushButton:hover, QPushButton:focus {{ border: 1px solid {accent}; }}")

    def _pick(self):
        c = QColorDialog.getColor(QColor(self.color), self, self.label)
        if c.isValid():
            self.on_pick(c.name())


class Key(QLabel):
    """A key hint that is also a button: `r roll`, the key in the accent and the
    label dim, the way the player draws them; underlined under the pointer."""

    def __init__(self, key: str, label: str, run):
        super().__init__()
        self.key, self.label, self.run = key, label, run
        self.colors = ("#888888", "#cccccc")
        self.hot = False
        self.setTextFormat(Qt.TextFormat.RichText)
        self.setCursor(Qt.CursorShape.PointingHandCursor)
        self.setContentsMargins(4, 2, 4, 2)
        self.paint(*self.colors)

    def paint(self, key_color: str, label_color: str):
        self.colors = (key_color, label_color)
        u = "text-decoration: underline;" if self.hot else ""
        lc = key_color if self.hot else label_color
        self.setText(f'<span style="color:{key_color};{u}">{self.key}</span> <span style="color:{lc};{u}">{self.label}</span>')

    def enterEvent(self, e):
        self.hot = True
        self.paint(*self.colors)

    def leaveEvent(self, e):
        self.hot = False
        self.paint(*self.colors)

    def mouseReleaseEvent(self, e):
        if e.button() == Qt.MouseButton.LeftButton and self.rect().contains(e.position().toPoint()):
            self.run()


class ThemeBuilder(QDialog):
    def __init__(self, parent=None):
        super().__init__(parent)
        self.setWindowTitle("orpheus · theme builder")
        self.setMinimumWidth(600)
        live = THEME[0] if THEME else None
        self._was = live.property("name") if live else ""
        start = live.current_palette() if live else {}
        self.core = {k: start.get(k) or d for k, d in
                     (("background", "#0b0d12"), ("foreground", "#d7dbe6"), ("accent", "#5b8cff"))}
        self.pinned: dict[str, str] = {}
        self.palette: dict = {}

        self._family = _mono()
        font = QFont(self._family)
        font.setPointSizeF(10)
        self.setFont(font)

        lay = QVBoxLayout(self)
        lay.setContentsMargins(18, 14, 18, 14)
        lay.setSpacing(8)

        self.head = QLabel()
        self.head.setTextFormat(Qt.TextFormat.RichText)
        lay.addWidget(self.head)

        top = QHBoxLayout()
        self.name_label = QLabel("name ❯")
        top.addWidget(self.name_label)
        self.name = QLineEdit(placeholderText="my-theme")
        top.addWidget(self.name, 1)
        lay.addLayout(top)

        self.core_head = QLabel()
        self.core_head.setTextFormat(Qt.TextFormat.RichText)
        lay.addWidget(self.core_head)
        core_row = QHBoxLayout()
        core_row.setSpacing(8)
        self.core_sw = {}
        for key, label in CORE:
            sw = Swatch(label, lambda c, k=key: self._set_core(k, c), big=True)
            self.core_sw[key] = sw
            core_row.addWidget(sw)
        core_row.addStretch(1)
        side = QVBoxLayout()
        side.setSpacing(0)
        self.roll_key = Key("r", "roll", self._roll)
        self.flip_key = Key("f", "flip light/dark", self._flip)
        side.addWidget(self.roll_key)
        side.addWidget(self.flip_key)
        side.addStretch(1)
        core_row.addLayout(side)
        lay.addLayout(core_row)

        self.hue_head = QLabel()
        self.hue_head.setTextFormat(Qt.TextFormat.RichText)
        lay.addWidget(self.hue_head)
        grid = QGridLayout()
        grid.setSpacing(8)
        self.hue_sw = {}
        for i, h in enumerate(themegen.HUES):
            sw = Swatch(h, lambda c, k=h: self._pin(k, c), lambda k=h: self._unpin(k))
            self.hue_sw[h] = sw
            grid.addWidget(sw, i // 4, i % 4, Qt.AlignmentFlag.AlignLeft)
        lay.addLayout(grid)

        self.sample_head = QLabel()
        self.sample_head.setTextFormat(Qt.TextFormat.RichText)
        lay.addWidget(self.sample_head)
        self.sample = QLabel()
        self.sample.setMinimumHeight(64)
        self.sample.setTextFormat(Qt.TextFormat.RichText)
        lay.addWidget(self.sample)

        buttons = QHBoxLayout()
        self.note = QLabel()
        buttons.addWidget(self.note, 1)
        self.cancel_key = Key("esc", "cancel", self.reject)
        self.save_key = Key("⏎", "save", self._save)
        buttons.addWidget(self.cancel_key)
        buttons.addWidget(self.save_key)
        lay.addLayout(buttons)

        QShortcut(QKeySequence("Ctrl+S"), self).activated.connect(self._save)
        self._refresh()

    def keyPressEvent(self, e):
        # ⏎ saves from anywhere (the name field included); esc is QDialog's reject.
        # r and f arrive here only when the name field did not take them as letters.
        if e.key() in (Qt.Key.Key_Return, Qt.Key.Key_Enter):
            self._save()
        elif e.text() == "r" and not self.name.hasFocus():
            self._roll()
        elif e.text() == "f" and not self.name.hasFocus():
            self._flip()
        else:
            super().keyPressEvent(e)

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
        # the dice keep the side you are on; f changes sides
        bg, fg, acc = themegen.random_seed(self.palette.get("mode") == "light")
        self.core = {"background": bg, "foreground": fg, "accent": acc}
        self.pinned.clear()
        self._refresh()

    def _flip(self):
        self.core["background"], self.core["foreground"] = self.core["foreground"], self.core["background"]
        self._refresh()

    def _refresh(self):
        c = self.core
        self.palette = themegen.palette(c["background"], c["foreground"], c["accent"], **self.pinned)
        p = self.palette
        bg, fg = p["background"], p["foreground"]
        acc = _ensure(p["accent"], bg, 3.0)          # as text: legible, as Tui.ensure does
        dim = _ensure(p["dark_foreground"], bg, 4.5)
        line = themegen.mix(fg, bg, 0.72)
        # the dialog wears the theme it is making
        # (the face goes in the sheet too: a re-polish drops a plain setFont)
        self.setStyleSheet(
            f'QDialog, QDialog * {{ font-family: "{self._family}"; font-size: 10pt; }}'
            f"QDialog {{ background: {bg}; color: {fg}; }}"
            f"QLabel {{ color: {fg}; background: transparent; }}"
            f"QLineEdit {{ background: {bg}; color: {fg}; border: 1px solid {line}; border-radius: 0px;"
            f" padding: 3px 6px; selection-background-color: {acc}; }}"
            f"QLineEdit:focus {{ border: 1px solid {acc}; }}"
            f"QToolTip {{ background: {bg}; color: {fg}; border: 1px solid {line}; }}")
        self.head.setText(_rule("THEME BUILDER", acc, line).replace("THEME BUILDER", f'<span style="color:{dim}">THEME BUILDER</span>'))
        self.core_head.setText(_rule(f'<span style="color:{dim}">three colours · click one to pick it</span>', acc, line))
        self.hue_head.setText(_rule(f'<span style="color:{dim}">hues · click to set one · right-click gives it back</span>', acc, line))
        self.sample_head.setText(_rule(f'<span style="color:{dim}">preview · the whole app is wearing it</span>', acc, line))
        self.name_label.setStyleSheet(f"color: {acc};")
        for k, sw in self.core_sw.items():
            sw.show_color(c[k], line=line, accent=acc)
        for k, sw in self.hue_sw.items():
            sw.show_color(p[k], k in self.pinned, line=line, accent=acc)
        for key in (self.roll_key, self.flip_key, self.cancel_key, self.save_key):
            key.paint(acc, dim)
        dots = "".join(f'<span style="color:{p[h]}">■</span>' for h in themegen.HUES)
        self.sample.setText(
            f'<div style="background:{bg}; padding:8px">'
            f'<span style="color:{acc}">▶ now playing</span>'
            f'<span style="color:{fg}">  Ship Is Not A Child · OTT</span><br>'
            f'<span style="color:{dim}">vol ▰▰▰▰▰▱▱▱  shuf  ↻ off  </span>{dots}</div>')
        self.sample.setStyleSheet(f"background:{bg}; border: 1px solid {line};")
        self.note.setText(f"{p['mode']} · {len(self.pinned)} pinned" if self.pinned else p["mode"])
        self.note.setStyleSheet(f"color: {dim};")
        if THEME:
            THEME[0].preview(self.palette)

    # ---- finishing ----------------------------------------------------------
    def _save(self):
        slug = _slug(self.name.text())
        if not slug:
            self.note.setText("name it first ↑")
            self.note.setStyleSheet(f"color: {self.palette.get('accent', '#ff5c7a')};")
            self.name.setFocus()
            return
        dest = user_themes_dir() / f"{slug}.toml"
        if dest.exists() or slug in theme_names():
            ok = QMessageBox.question(self, "replace?", f"a theme called {slug} already exists. replace it?")
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
