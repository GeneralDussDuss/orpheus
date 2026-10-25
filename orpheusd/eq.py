"""Ten-band equalizer, built as an mpv filter chain.

The EQ lives inside mpv rather than in PipeWire. A filter-chain sink would be
system-wide, would have to be re-linked every time the output device changed,
and would give up any claim to an untouched signal path; this sits between the
decoder and the audio output, follows the device automatically, and costs
nothing when it is switched off.

`af-command` does not reach into a lavfi graph on mpv 0.41 -- every target form
returns "error running command" -- so changing a gain rebuilds the chain with
`set_property af`. That is cheap, but it rebuilds the audio graph, so callers
should debounce a slider drag rather than sending a command per pixel.

Bypass is real bypass: a flat or disabled EQ produces an empty filter string,
and mpv is left with no filter at all rather than a unity-gain one.
"""

from __future__ import annotations

import json
import os
import re
from pathlib import Path

# Band centres. Ten octave-ish steps, the span people expect from a graphic EQ
# and the grid published headphone corrections are easiest to sample onto.
BANDS: tuple[int, ...] = (31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000)

GAIN_LIMIT = 12.0   # dB, each way
GAIN_STEP = 0.5     # dB, the resolution the UI should move in
PEAK_Q = 1.4        # ~2/3 octave: adjacent bands overlap without ripple
SHELF_Q = 0.7       # gentler slope for the two shelves

# The end bands are shelves, not peaks. A peaking filter at 31 Hz with Q=1.4 has
# almost no effect by 20 Hz, so "lift the sub-bass" would not do what it says;
# a low shelf carries the gain down to DC. Same argument at the top end.

# Device corrections live in the user's own state directory, NOT in this repo.
# The obvious source for them is AutoEq, whose MIT licence covers its code and
# not its data: the measurements come from oratory1990, Rtings, Super Review and
# others, none of whom have granted redistribution (the maintainer confirms this
# in AutoEq issue #790). So Orpheus ships the importer and no curves. Point it at
# a FixedBandEQ.txt and the numbers stay on your machine.
_STATE_DIR = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / "orpheus"
PRESETS_FILE = _STATE_DIR / "eq-presets.json"

DEFAULT: dict = {
    "enabled": False,
    "gains": [0.0] * len(BANDS),
    "preamp": None,   # None means "work it out from the gains"
    "preset": None,
}


def clamp_gain(value) -> float:
    try:
        g = float(value)
    except (TypeError, ValueError):
        return 0.0
    g = max(-GAIN_LIMIT, min(GAIN_LIMIT, g))
    # Snap to the UI's step so the stored value matches what is displayed.
    return round(g / GAIN_STEP) * GAIN_STEP


def normalize(state: dict | None) -> dict:
    """Coerce anything we were handed into a complete, valid EQ state."""
    s = dict(DEFAULT)
    s["gains"] = list(DEFAULT["gains"])
    if not isinstance(state, dict):
        return s

    gains = state.get("gains")
    if isinstance(gains, (list, tuple)):
        for i in range(min(len(BANDS), len(gains))):
            s["gains"][i] = clamp_gain(gains[i])

    s["enabled"] = bool(state.get("enabled", False))

    preamp = state.get("preamp")
    if preamp is not None:
        try:
            s["preamp"] = max(-24.0, min(0.0, round(float(preamp) * 2) / 2))
        except (TypeError, ValueError):
            s["preamp"] = None

    preset = state.get("preset")
    s["preset"] = preset if isinstance(preset, str) and preset else None
    return s


def is_flat(gains) -> bool:
    return all(abs(g) < 1e-6 for g in gains)


def auto_preamp(gains) -> float:
    """Headroom for the largest boost.

    Orpheus runs mpv with --replaygain-clip=no, so the signal is already allowed
    above 0 dBFS before the EQ touches it. Boosting a band on top of that clips
    at the sink, and the clipping is in the integer conversion at the very end
    where nothing can catch it. Pull the whole chain down by the biggest boost.
    """
    peak = max([0.0, *(float(g) for g in gains)])
    return -round(peak * 2) / 2


def effective_preamp(state: dict) -> float:
    s = normalize(state)
    return s["preamp"] if s["preamp"] is not None else auto_preamp(s["gains"])


def build_chain(state: dict | None) -> str:
    """The mpv `af` string for this state, or "" to mean no filter at all."""
    s = normalize(state)
    if not s["enabled"] or is_flat(s["gains"]):
        return ""

    stages: list[str] = []
    pre = effective_preamp(s)
    if abs(pre) >= 0.05:
        # precision=float keeps the attenuation out of the integer domain
        stages.append(f"volume@pre={pre:g}dB:precision=float")

    last = len(BANDS) - 1
    for i, (freq, gain) in enumerate(zip(BANDS, s["gains"])):
        if abs(gain) < 1e-6:
            continue  # a band at 0 dB is a biquad doing nothing; leave it out
        if i == 0:
            stages.append(f"lowshelf@b{i}=f={freq}:t=q:w={SHELF_Q}:g={gain:g}")
        elif i == last:
            stages.append(f"highshelf@b{i}=f={freq}:t=q:w={SHELF_Q}:g={gain:g}")
        else:
            stages.append(f"equalizer@b{i}=f={freq}:t=q:w={PEAK_Q}:g={gain:g}")

    if not stages:
        return ""
    return "@eq:lavfi=[" + ",".join(stages) + "]"


# ---- presets ----------------------------------------------------------------

# Tone shapes, not device corrections. These are deliberately mild: an EQ preset
# that announces itself is a preset people turn off a week later.
TONE_PRESETS: list[dict] = [
    {"id": "flat", "name": "Flat", "kind": "tone",
     "gains": [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
     "note": "No correction. The signal path is left alone."},
    {"id": "bass", "name": "Bass Lift", "kind": "tone",
     "gains": [5.0, 4.0, 2.5, 1.0, 0, 0, 0, 0, 0, 0],
     "note": "Weight below 250 Hz, without muddying the vocal range."},
    {"id": "vocal", "name": "Vocal", "kind": "tone",
     "gains": [-1.0, -1.0, 0, 1.0, 2.0, 2.5, 2.0, 0.5, 0, 0],
     "note": "Brings the voice forward and steps the low end back a little."},
    {"id": "loudness", "name": "Loudness", "kind": "tone",
     "gains": [4.5, 3.5, 1.5, 0, -1.0, -1.0, 0, 1.5, 3.0, 3.5],
     "note": "The classic smile curve, for listening quietly."},
    {"id": "tame", "name": "Tame Treble", "kind": "tone",
     "gains": [0, 0, 0, 0, 0, 0, -1.5, -3.0, -2.5, -1.5],
     "note": "Takes the edge off bright or sibilant recordings."},
    {"id": "podcast", "name": "Speech", "kind": "tone",
     "gains": [-4.0, -3.0, -1.0, 1.0, 2.5, 3.0, 2.5, 1.0, -1.0, -2.0],
     "note": "Narrows to the speech band; useful for interviews and mixes."},
]


def _load_device_presets() -> list[dict]:
    """Headphone corrections the user has imported. Never shipped with Orpheus."""
    try:
        raw = json.loads(PRESETS_FILE.read_text())
    except Exception:
        return []
    out = []
    for item in raw.get("devices", []):
        gains = item.get("gains")
        if not isinstance(gains, (list, tuple)) or len(gains) != len(BANDS):
            continue
        out.append({
            "id": str(item.get("id", "")),
            "name": str(item.get("name", "")),
            "kind": "device",
            "gains": [clamp_gain(g) for g in gains],
            "preamp": item.get("preamp"),
            "note": item.get("note", ""),
            "source": item.get("source", ""),
            "confidence": item.get("confidence", ""),
        })
    return [p for p in out if p["id"] and p["name"]]


def presets() -> list[dict]:
    return TONE_PRESETS + _load_device_presets()


def preset_by_id(preset_id: str) -> dict | None:
    for p in presets():
        if p["id"] == preset_id:
            return p
    return None


def attribution() -> dict:
    """Where the device corrections came from, for the UI and the README."""
    try:
        raw = json.loads(PRESETS_FILE.read_text())
    except Exception:
        return {}
    return raw.get("attribution", {})


def describe() -> dict:
    """Everything a client needs to draw the EQ without hardcoding the spec."""
    return {
        "bands": list(BANDS),
        "limit": GAIN_LIMIT,
        "step": GAIN_STEP,
        "presets": presets(),
        "attribution": attribution(),
    }


# ---- importing a correction -------------------------------------------------

# AutoEq's "<Device> FixedBandEQ.txt" is already on exactly these ten centres,
# least-squares fitted to the full correction curve, which tracks it better than
# reading the curve off at ten points. Lines look like:
#   Preamp: -6.8 dB
#   Filter 1: ON PK Fc 31 Hz Gain 5.3 dB Q 1.41
_FILTER_RE = re.compile(
    r"Filter\s+\d+:\s*ON\s+(?P<type>PK|LS|HS|LSC|HSC)\s+Fc\s+(?P<fc>[\d.]+)\s*Hz\s+"
    r"Gain\s+(?P<gain>-?[\d.]+)\s*dB", re.I)
_PREAMP_RE = re.compile(r"Preamp:\s*(?P<v>-?[\d.]+)\s*dB", re.I)


def parse_fixed_band(text: str) -> dict:
    """Read a FixedBandEQ.txt into our ten bands.

    Raises ValueError if it is not a fixed-band file on our centres, rather than
    silently importing a curve that means something else.
    """
    found: dict[int, float] = {}
    for m in _FILTER_RE.finditer(text or ""):
        fc = float(m.group("fc"))
        # match to the nearest band centre, within 5% - these files are exact,
        # so anything further away is a different band layout
        for i, band in enumerate(BANDS):
            if abs(fc - band) <= band * 0.05:
                found[i] = clamp_gain(m.group("gain"))
                break

    if len(found) < len(BANDS) // 2:
        raise ValueError(
            "not a ten-band correction on Orpheus's centres - use AutoEq's "
            "'FixedBandEQ.txt', not ParametricEQ.txt or GraphicEQ.txt")

    gains = [found.get(i, 0.0) for i in range(len(BANDS))]
    pm = _PREAMP_RE.search(text or "")
    preamp = None
    if pm:
        try:
            preamp = max(-24.0, min(0.0, round(float(pm.group("v")) * 2) / 2))
        except ValueError:
            preamp = None

    warnings = []
    # AutoEq fits out to 20 kHz where coupler measurements stop being reliable,
    # so the top band is often a large cut that is an artefact of the fit rather
    # than anything you would hear. Flag it; do not quietly rewrite their data.
    if abs(gains[-1]) >= 8.0:
        warnings.append(
            f"the {BANDS[-1] // 1000} kHz band is {gains[-1]:+g} dB, which is usually an "
            "artefact of fitting above the reliable measurement range - consider "
            "reducing it")
    if max(gains) >= 10.0:
        warnings.append("large boosts need headroom; the preamp will be steep")

    return {"gains": gains, "preamp": preamp, "warnings": warnings}


def _slugify(name: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", (name or "").lower()).strip("-")
    return slug or "device"


def save_device_preset(name: str, gains, preamp=None, source: str = "", note: str = "") -> dict:
    raw = {}
    try:
        raw = json.loads(PRESETS_FILE.read_text())
    except Exception:
        raw = {}
    devices = [d for d in raw.get("devices", []) if isinstance(d, dict)]

    entry = {
        "id": _slugify(name),
        "name": name.strip() or "Device",
        "gains": [clamp_gain(g) for g in gains],
        "preamp": preamp,
        "source": source,
        "note": note,
    }
    devices = [d for d in devices if d.get("id") != entry["id"]] + [entry]
    raw["devices"] = devices
    PRESETS_FILE.parent.mkdir(parents=True, exist_ok=True)
    PRESETS_FILE.write_text(json.dumps(raw, indent=2) + "\n")
    return entry


def delete_device_preset(preset_id: str) -> bool:
    try:
        raw = json.loads(PRESETS_FILE.read_text())
    except Exception:
        return False
    before = raw.get("devices", [])
    after = [d for d in before if d.get("id") != preset_id]
    if len(after) == len(before):
        return False
    raw["devices"] = after
    PRESETS_FILE.write_text(json.dumps(raw, indent=2) + "\n")
    return True
