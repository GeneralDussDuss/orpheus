"""Full Omarchy-style palettes from three colours.

A theme is the key set of an Omarchy colors.toml: background and foreground in
four shades each, an accent, and eight hues with bright variants. Hand-picking
twenty-odd colours is what makes themes tedious, so this derives them from a
background, a foreground and an accent: shades by mixing toward black, white or
each other, hues by walking the colour wheel at the accent's own saturation and
a lightness that reads on the background. Any key passed in is kept as given.
"""
from __future__ import annotations

import colorsys
import random

HUES = {"red": 0, "orange": 28, "yellow": 48, "green": 125, "cyan": 185,
        "blue": 218, "magenta": 290, "brown": 22}
KEYS = ["mode", "accent", "selection", "muted",
        "background", "dark_background", "darker_background", "lighter_background",
        "foreground", "dark_foreground", "light_foreground", "bright_foreground",
        *HUES, *(f"bright_{h}" for h in HUES if h != "brown")]


def _rgb(hexstr: str) -> tuple[float, float, float]:
    h = hexstr.lstrip("#")
    return tuple(int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))


def _hex(rgb) -> str:
    return "#" + "".join(f"{round(max(0.0, min(1.0, c)) * 255):02x}" for c in rgb)


def mix(a: str, b: str, t: float) -> str:
    x, y = _rgb(a), _rgb(b)
    return _hex(tuple(x[i] + (y[i] - x[i]) * t for i in range(3)))


def luminance(c: str) -> float:
    r, g, b = _rgb(c)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def _hls(c: str):
    return colorsys.rgb_to_hls(*_rgb(c))


def _from_hls(h, l, s) -> str:
    return _hex(colorsys.hls_to_rgb(h % 1.0, max(0.0, min(1.0, l)), max(0.0, min(1.0, s))))


def palette(background: str, foreground: str, accent: str, **given) -> dict:
    """Every colors.toml key, derived; keyword arguments override single keys."""
    light = luminance(background) > 0.5
    _, _, acc_s = _hls(accent)
    sat = max(0.45, min(0.85, acc_s))
    # Hues sit far enough from the background to read as text on it.
    hue_l = 0.42 if light else 0.66
    shade = "#000000" if not light else "#ffffff"
    p = {
        "mode": "light" if light else "dark",
        "accent": accent,
        "selection": mix(background, accent, 0.28),
        "muted": mix(background, foreground, 0.32),
        "background": background,
        "dark_background": mix(background, shade if not light else foreground, 0.25 if not light else 0.05),
        "darker_background": mix(background, shade if not light else foreground, 0.45 if not light else 0.10),
        "lighter_background": mix(background, foreground, 0.08),
        "foreground": foreground,
        "dark_foreground": mix(foreground, background, 0.45),
        "light_foreground": mix(foreground, "#ffffff" if not light else "#000000", 0.15),
        "bright_foreground": mix(foreground, "#ffffff" if not light else "#000000", 0.35),
    }
    # A fifth of the accent in every hue: the eight stay recognisable as red,
    # green and so on, but read as one family rather than a stock terminal set.
    for name, deg in HUES.items():
        s, l = (sat * 0.55, hue_l - 0.18) if name == "brown" else (sat, hue_l)
        p[name] = mix(_from_hls(deg / 360, l, s), accent, 0.2)
        if name != "brown":
            p[f"bright_{name}"] = mix(_from_hls(deg / 360, l + (-0.08 if light else 0.08), min(1.0, s + 0.1)),
                                      accent, 0.12)
    p.update({k: v for k, v in given.items() if k in KEYS and v})
    return p


def random_seed(light: bool = False) -> tuple[str, str, str]:
    """A background, foreground and accent that go together: a tinted near-black
    (or near-white), a soft text colour of the same tint, a saturated accent."""
    tint = random.random()
    if light:
        bg = _from_hls(tint, random.uniform(0.92, 0.97), random.uniform(0.15, 0.4))
        fg = _from_hls(tint, random.uniform(0.15, 0.22), random.uniform(0.1, 0.25))
        acc_l = random.uniform(0.38, 0.48)
    else:
        bg = _from_hls(tint, random.uniform(0.05, 0.11), random.uniform(0.2, 0.45))
        fg = _from_hls(tint, random.uniform(0.82, 0.9), random.uniform(0.1, 0.3))
        acc_l = random.uniform(0.6, 0.7)
    acc = _from_hls(tint + random.choice([0.5, 0.33, -0.33, 0.12, -0.12]), acc_l, random.uniform(0.65, 0.95))
    return bg, fg, acc


def to_toml(p: dict, comment: str = "") -> str:
    lines = [f"# {comment}", ""] if comment else []
    for k in KEYS:
        if k in p:
            lines.append(f'{k} = "{p[k]}"')
            if k in ("mode", "muted", "lighter_background", "bright_foreground", "brown"):
                lines.append("")
    return "\n".join(lines).rstrip() + "\n"
