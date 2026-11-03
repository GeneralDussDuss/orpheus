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

A headphone correction (AutoEq's ParametricEQ.txt, fetched by autoeq.py) rides
in the same graph, in front of the ten bands: one preamp, then the
correction's own stages, then the user's curve on top. It is validated here,
in Python, before any of it reaches mpv, because mpv swallows a bad `af`
without a word.
"""

from __future__ import annotations

import json
import math
import re

from .system import STATE_DIR

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
PRESETS_FILE = STATE_DIR / "eq-presets.json"

DEFAULT: dict = {
    "enabled": False,
    "gains": [0.0] * len(BANDS),
    "preamp": None,   # None means "work it out from the gains"
    "preset": None,
    "autoeq": None,     # the headphone correction, parsed; see _norm_autoeq
    "autoeqOn": False,
}

# ---- headphone correction (AutoEq parametric) --------------------------------

AE_MAX_FILTERS = 20
# Hard limits: anything outside these is refused, not clamped. They are wider
# than AutoEq's own optimiser bounds (fc 20-10k, peak Q 0.18-6, shelf Q 0.4-0.7,
# gain +-20; autoeq/constants.py) so a future AutoEq tweak still loads; values
# past AutoEq's bounds only earn a warning.
AE_FC = (10.0, 20000.0)
AE_Q = (0.05, 10.0)
AE_GAIN = 30.0
AE_TYPES = {"PK": "equalizer", "LSC": "lowshelf", "HSC": "highshelf",
            "LS": "lowshelf", "HS": "highshelf"}
_AE_CANON = {"PK": "PK", "LSC": "LSC", "HSC": "HSC", "LS": "LSC", "HS": "HSC"}
_AE_SOFT_FC = (20.0, 10000.0)
_AE_SOFT_PEAK_Q = (0.18, 6.0)
_AE_SOFT_SHELF_Q = (0.4, 0.7)
_AE_SOFT_GAIN = 20.0
_AE_FIELDS = ("path", "name", "source", "rig", "form")


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

    s["autoeq"] = _norm_autoeq(state.get("autoeq"))
    s["autoeqOn"] = bool(state.get("autoeqOn")) and s["autoeq"] is not None
    return s


def _check_filter(kind, fc, gain, q) -> dict:
    """One parametric stage, canonical and inside the hard limits, or ValueError."""
    canon = _AE_CANON.get(str(kind).upper())
    if canon is None:
        raise ValueError(f"unknown filter type {kind!r}")
    fc, gain, q = float(fc), float(gain), float(q)
    if not all(math.isfinite(v) for v in (fc, gain, q)):
        raise ValueError("a filter value is not a number")
    if not AE_FC[0] <= fc <= AE_FC[1]:
        raise ValueError(f"{fc:g} Hz is outside {AE_FC[0]:g}-{AE_FC[1]:g} Hz")
    if not AE_Q[0] <= q <= AE_Q[1]:
        raise ValueError(f"Q {q:g} is outside {AE_Q[0]:g}-{AE_Q[1]:g}")
    if abs(gain) > AE_GAIN:
        raise ValueError(f"{gain:+g} dB is beyond +-{AE_GAIN:g} dB")
    return {"type": canon, "fc": round(fc, 1), "gain": round(gain, 2), "q": round(q, 3)}


def _norm_autoeq(v) -> dict | None:
    """The stored correction, revalidated, or None. Never raises: this runs on
    every prefs restore, and a hand-edited daemon.json must not stop the daemon."""
    if not isinstance(v, dict):
        return None
    path, name = v.get("path"), v.get("name")
    if not (isinstance(path, str) and isinstance(name, str) and path and name
            and len(path) <= 300 and len(name) <= 300):
        return None
    filters = v.get("filters")
    if not isinstance(filters, list) or not 0 < len(filters) <= AE_MAX_FILTERS:
        return None
    out: dict = {k: (v.get(k) if isinstance(v.get(k), str) else "")[:300] for k in _AE_FIELDS}
    try:
        out["filters"] = [_check_filter(f["type"], f["fc"], f["gain"], f["q"]) for f in filters]
        pre = float(v.get("preamp") or 0.0)
        out["preamp"] = max(-24.0, min(0.0, round(pre, 2))) if math.isfinite(pre) else 0.0
    except (TypeError, ValueError, KeyError):
        return None
    return out


def autoeq_live(s: dict) -> bool:
    """True when a correction is chosen and switched on (a normalized state)."""
    return bool(s.get("autoeqOn")) and s.get("autoeq") is not None


def state_from_preset(preset: dict, current: dict | None, enabled: bool = True) -> dict:
    """The EQ state a preset makes. A preset is a ten-band shape, so it replaces
    the gains and the preamp and leaves the headphone correction where it was:
    cycling `p` must never drop the user's headphones."""
    cur = current if isinstance(current, dict) else {}
    return {
        "enabled": bool(enabled),
        "gains": list(preset["gains"]),
        "preamp": preset.get("preamp"),
        "preset": preset["id"],
        "autoeq": cur.get("autoeq"),
        "autoeqOn": bool(cur.get("autoeqOn")),
    }


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


# ---- frequency response -------------------------------------------------------

# RBJ cookbook biquads: the formulas both AutoEq (peq.py) and ffmpeg's
# af_biquads.c use, so this is the curve mpv actually plays. Eq.js mirrors it
# line for line, and tests/test_autoeq.py holds the two to 1e-6 dB.

def band_stages(gains) -> list[dict]:
    """The ten bands as stages, zero bands left out exactly as build_chain does."""
    last = len(BANDS) - 1
    out = []
    for i, (freq, gain) in enumerate(zip(BANDS, gains)):
        if abs(gain) < 1e-6:
            continue
        kind = "LSC" if i == 0 else "HSC" if i == last else "PK"
        out.append({"type": kind, "fc": float(freq), "gain": float(gain),
                    "q": PEAK_Q if kind == "PK" else SHELF_Q})
    return out


def _coeffs(st: dict, fs: float) -> tuple:
    A = 10 ** (st["gain"] / 40)
    w0 = 2 * math.pi * st["fc"] / fs
    alpha = math.sin(w0) / (2 * st["q"])
    c = math.cos(w0)
    if st["type"] == "PK":
        return (1 + alpha * A, -2 * c, 1 - alpha * A), (1 + alpha / A, -2 * c, 1 - alpha / A)
    sq = 2 * math.sqrt(A) * alpha
    if st["type"] == "LSC":
        b = (A * ((A + 1) - (A - 1) * c + sq), 2 * A * ((A - 1) - (A + 1) * c),
             A * ((A + 1) - (A - 1) * c - sq))
        a = ((A + 1) + (A - 1) * c + sq, -2 * ((A - 1) + (A + 1) * c),
             (A + 1) + (A - 1) * c - sq)
    else:
        b = (A * ((A + 1) + (A - 1) * c + sq), -2 * A * ((A - 1) + (A + 1) * c),
             A * ((A + 1) + (A - 1) * c - sq))
        a = ((A + 1) - (A - 1) * c + sq, 2 * ((A - 1) - (A + 1) * c),
             (A + 1) - (A - 1) * c - sq)
    return b, a


def stages_db(stages, freqs, fs: float = 48000.0) -> list[float]:
    """Summed |H| in dB of a cascade of {type, fc, gain, q} stages."""
    co = [_coeffs(st, fs) for st in stages]
    out = []
    for f in freqs:
        w = 2 * math.pi * f / fs
        c1, s1, c2, s2 = math.cos(w), math.sin(w), math.cos(2 * w), math.sin(2 * w)
        db = 0.0
        for b, a in co:
            nr, ni = b[0] + b[1] * c1 + b[2] * c2, b[1] * s1 + b[2] * s2
            dr, di = a[0] + a[1] * c1 + a[2] * c2, a[1] * s1 + a[2] * s2
            db += 10 * math.log10((nr * nr + ni * ni) / (dr * dr + di * di))
        out.append(db)
    return out


def response_db(gains, filters, freqs, fs: float = 48000.0) -> list[float]:
    """The ten bands plus `filters`, in dB at each frequency. The preamp is a
    flat offset and is left out. fs=48k: real rates differ by <0.1 dB below 16k."""
    return stages_db(band_stages(gains) + list(filters or []), freqs, fs)


# 240 log-spaced points over the audible range plus every band centre, so the
# top of a narrow peak on a centre is never stepped over. Each call adds the
# correction's own centres for the same reason.
PEAK_GRID: tuple[float, ...] = (tuple(20.0 * 1000.0 ** (i / 239) for i in range(240))
                                + tuple(float(b) for b in BANDS))


def auto_preamp_live(s: dict) -> float:
    """Headroom for the whole cascade, correction included.

    Overlapping filters do not peak where any one slider says (a +6 dB shelf
    under a +3 dB band peaks wherever the two meet), so with a correction live
    the rule is the measured one: the top of the combined response, rounded up
    to the next half dB. Exactly enough, never quieter than it needs to be.
    Without one it is auto_preamp(), unchanged, which the UI mirrors.
    """
    if not autoeq_live(s):
        return auto_preamp(s["gains"])
    filters = s["autoeq"]["filters"]
    grid = PEAK_GRID + tuple(f["fc"] for f in filters)
    peak = max(0.0, max(response_db(s["gains"], filters, grid)))
    return max(-24.0, -math.ceil(peak * 2 - 1e-9) / 2)


def effective_preamp(state: dict) -> float:
    s = normalize(state)
    return s["preamp"] if s["preamp"] is not None else auto_preamp_live(s)


def build_chain(state: dict | None) -> str:
    """The mpv `af` string for this state, or "" to mean no filter at all."""
    s = normalize(state)
    live = autoeq_live(s)
    if not s["enabled"] or (is_flat(s["gains"]) and not live):
        return ""

    stages: list[str] = []
    pre = effective_preamp(s)
    if abs(pre) >= 0.05:
        # precision=float keeps the attenuation out of the integer domain
        stages.append(f"volume@pre={pre:g}dB:precision=float")

    if live:
        # the headphone correction first, in the file's own order (AutoEq does
        # not sort by frequency), so the user's curve sits on a corrected headphone
        for j, f in enumerate(s["autoeq"]["filters"]):
            stages.append(f"{AE_TYPES[f['type']]}@a{j}=f={f['fc']:g}:t=q:w={f['q']:g}:g={f['gain']:g}")

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
        "autoeqAttribution": "corrections by AutoEq (github.com/jaakkopasanen/AutoEq) from the "
                             "named measurement source, fetched to this machine on request",
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
            "'FixedBandEQ.txt' here; for ParametricEQ.txt use the AutoEQ picker "
            "(A on the equalizer page)")

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


# ParametricEQ.txt is the correction itself, as AutoEq's optimiser left it.
#   Preamp: -6.3 dB
#   Filter 1: ON LSC Fc 105 Hz Gain 6.5 dB Q 0.70
_PARAM_RE = re.compile(
    r"Filter\s+\d+:\s*(?P<on>ON|OFF)\s+(?P<type>PK|LSC|HSC|LS|HS)\s+Fc\s+(?P<fc>[\d.]+)\s*Hz\s+"
    r"Gain\s+(?P<gain>-?[\d.]+)\s*dB(?:\s+Q\s+(?P<q>[\d.]+))?", re.I)


def parse_parametric(text: str) -> dict:
    """Read an AutoEq ParametricEQ.txt into {preamp, filters, warnings}.

    Raises ValueError for anything that is not one, or that carries a value
    mpv could not run; nothing half-parsed is ever applied.
    """
    filters: list[dict] = []
    soft: dict[str, list[int]] = {}
    for n, m in enumerate(_PARAM_RE.finditer(text or ""), 1):
        if m.group("on").upper() == "OFF":
            continue
        kind, q = m.group("type").upper(), m.group("q")
        if q is None:
            if kind not in ("LS", "HS"):
                raise ValueError(f"filter {n} has no Q")
            q = SHELF_Q
            soft.setdefault("shelf without a Q, taken as 0.7", []).append(n)
        try:
            f = _check_filter(kind, m.group("fc"), m.group("gain"), q)
        except ValueError as e:
            raise ValueError(f"filter {n}: {e}") from None
        if abs(f["gain"]) < 0.05:
            continue                   # a stage doing nothing; leave it out
        if not _AE_SOFT_FC[0] <= f["fc"] <= _AE_SOFT_FC[1]:
            soft.setdefault("centre outside AutoEq's usual 20 Hz-10 kHz", []).append(n)
        lo, hi = _AE_SOFT_PEAK_Q if f["type"] == "PK" else _AE_SOFT_SHELF_Q
        if not lo - 1e-9 <= f["q"] <= hi + 1e-9:
            soft.setdefault(("peak" if f["type"] == "PK" else "shelf")
                            + " Q outside AutoEq's usual range", []).append(n)
        if abs(f["gain"]) > _AE_SOFT_GAIN:
            soft.setdefault("gain beyond AutoEq's usual +-20 dB", []).append(n)
        filters.append(f)

    if not filters:
        raise ValueError("not an AutoEq ParametricEQ.txt (no filters in it)")
    if len(filters) > AE_MAX_FILTERS:
        raise ValueError(f"{len(filters)} filters is more than the {AE_MAX_FILTERS} Orpheus takes")
    warnings = [f"{what} (filter {', '.join(map(str, ns))})" for what, ns in soft.items()]

    preamp = 0.0
    pm = _PREAMP_RE.search(text or "")
    if pm is None:
        warnings.append("no Preamp line; the headroom is worked out from the curve")
    else:
        try:
            preamp = max(-24.0, min(0.0, round(float(pm.group("v")), 2)))
        except ValueError:
            raise ValueError("the Preamp line is not a number") from None
    return {"preamp": preamp, "filters": filters, "warnings": warnings}


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
