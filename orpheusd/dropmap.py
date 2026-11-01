"""The drop map: one track analysed ahead of time, for the visualizer's Director.

Run as a worker (`python -m orpheusd.dropmap`) by orpheusd/analysis.py, one at a
time, at idle priority: it reads one JSON job line on stdin, decodes the track
with ffmpeg (22050 Hz mono, one thread, streamed through a pipe), and prints one
JSON map line on stdout -- beats, bars, builds, drops, sections, per-second
energy, bpm and how much to trust it. The daemon never imports numpy; killing
this process is the whole of cancellation, and its memory goes back when it exits.

The analysis, end to end:
  features   Hann frames (1024, hop 512), log-mel flux (all bands, and the
             bands under 200 Hz alone) with the local mean removed: the onset
             envelopes. Power under 150 Hz (sub), over 4 kHz (hi) and in total.
  tempo      autocorrelation of the envelope over 60-200 BPM under a broad
             prior at 120, snapped to TIDAL's own bpm when an octave of it fits.
  beats      Ellis's dynamic-programming tracker: the beat sequence that best
             sits on the onsets while keeping close to the period.
  bars       beat 1 is the slot (of four) with the heaviest low onsets and the
             most spectral change; each drop re-anchors it on its own beat.
  drops      a bar whose energy jumps 3 dB over the bars before the riser and
             whose sub jumps 6 dB over the four before it, at near full level;
             clustered, the earliest bar of a cluster wins.
  sections   intro / build / drop / breakdown / steady per bar from the same
             tables, on 2-bar maxima so one riff dip does not flicker.

Nothing here ever logs, prints or embeds the job's `source` (it can be a signed
stream URL): ffmpeg's errors pass through `redact` before they leave.
"""
from __future__ import annotations

import io
import json
import os
import re
import signal
import subprocess
import sys
import threading
import time
from dataclasses import dataclass

# One BLAS thread before numpy loads (audiocap.py does the same): the analysis
# is small, and a pool of spinning threads is exactly what a game would feel.
for _v in ("OPENBLAS_NUM_THREADS", "OMP_NUM_THREADS", "MKL_NUM_THREADS"):
    os.environ.setdefault(_v, "1")
try:
    import numpy as np
except ImportError:      # the daemon reports "numpy missing"; the map is optional
    np = None

SR, N_FFT, HOP, N_MEL = 22050, 1024, 512, 40        # 43.07 frames/s
BLOCK = 2048                                       # frames per feature block
MAX_SECONDS = 1200
BPM_LO, BPM_HI, TIGHTNESS = 60.0, 200.0, 100.0
DROP_DE_MIN, DROP_DS_MIN, DROP_SPACING_BARS = 3.0, 6.0, 8
BUILD_BARS, DROP_SECTION_BARS = 8, 8
WHITELIST = "file,http,https,tcp,tls,crypto,data"
MAP_V = 1
WINDOWS = sys.platform == "win32"
IDLE_FLAGS = (0x40 | 0x08000000) if WINDOWS else 0  # IDLE_PRIORITY_CLASS | CREATE_NO_WINDOW


class DecodeError(Exception):
    pass


def redact(s: str) -> str:
    return re.sub(r"https?://\S+", "<url>", s or "")


def ffmpeg_cmd(ffmpeg: str, source: str, dash: bool, max_seconds: float) -> list[str]:
    # TIDAL's DASH manifest is a local file whose segments are https URLs:
    # ffmpeg refuses to follow them from a file without the whitelist.
    return [ffmpeg, "-nostdin", "-hide_banner", "-loglevel", "error", "-threads", "1", "-rw_timeout", "20000000",
            *(["-protocol_whitelist", WHITELIST] if dash else []),
            "-t", str(max_seconds), "-i", source, "-vn", "-map", "a:0", "-ac", "1", "-ar", str(SR),
            "-f", "s16le", "pipe:1"]


# ---- features ---------------------------------------------------------------

def mel_matrix(sr: int, n_fft: int, n_bands: int, fmin: float = 30.0):
    """Triangular mel filters over the rfft bins, and their centre frequencies."""
    fmax = sr / 2
    hz2mel = lambda f: 2595.0 * np.log10(1.0 + f / 700.0)
    mel2hz = lambda m: 700.0 * (10.0 ** (m / 2595.0) - 1.0)
    pts = mel2hz(np.linspace(hz2mel(fmin), hz2mel(fmax), n_bands + 2))
    bins = np.fft.rfftfreq(n_fft, 1.0 / sr)
    W = np.zeros((n_bands, bins.size), dtype=np.float32)
    for i in range(n_bands):
        lo, c, hi = pts[i], pts[i + 1], pts[i + 2]
        W[i] = np.clip(np.minimum((bins - lo) / max(c - lo, 1e-6), (hi - bins) / max(hi - c, 1e-6)), 0, 1)
    return W, pts[1:-1]


@dataclass
class Features:
    env: "np.ndarray"        # onset envelope (log-mel flux, local mean removed), 0..1 per frame
    lenv: "np.ndarray"       # the same over the mel bands under 200 Hz (kicks)
    sub: "np.ndarray"        # power under 150 Hz per frame
    hi: "np.ndarray"         # power over 4 kHz
    tot: "np.ndarray"        # total power
    rms_s: "np.ndarray"      # RMS per whole second
    n_samples: int
    sr: int = SR

    @property
    def fr(self) -> float:
        return self.sr / HOP

    @property
    def duration(self) -> float:
        return self.n_samples / self.sr


def _onset(f):
    loc = np.convolve(f, np.ones(16, np.float32) / 16, mode="same")
    e = np.maximum(f - loc, 0)
    return (e / (e.max() + 1e-9)).astype(np.float32) if e.size else e.astype(np.float32)


class _Featurer:
    """Feeds samples in any chunking and gives the same frames as one pass:
    the last N_FFT - HOP samples (plus any remainder short of a hop) carry over,
    and so does the last mel row the flux is measured against."""

    def __init__(self, sr: int):
        self.sr = sr
        self.win = np.hanning(N_FFT).astype(np.float32)
        W, centres = mel_matrix(sr, N_FFT, N_MEL)
        self.Wt = np.ascontiguousarray(W.T)
        self.lowmel = centres < 200
        bins = np.fft.rfftfreq(N_FFT, 1.0 / sr)
        self.sub_b, self.hi_b = bins < 150, bins > 4000
        self.buf = np.zeros(0, np.float32)
        self.prev = None
        self.out = {k: [] for k in ("flux", "lflux", "sub", "hi", "tot")}
        self.sec = np.zeros(0, np.float32)      # samples of the second in progress
        self.rms: list = []
        self.n = 0

    def push(self, x):
        self.n += x.size
        s = np.concatenate([self.sec, x])
        whole = (s.size // self.sr) * self.sr
        if whole:
            self.rms.append(np.sqrt((s[:whole].reshape(-1, self.sr).astype(np.float64) ** 2).mean(1)))
        self.sec = s[whole:]
        self.buf = np.concatenate([self.buf, x])
        if self.buf.size < N_FFT:
            return
        k = 1 + (self.buf.size - N_FFT) // HOP
        frames = np.lib.stride_tricks.as_strided(self.buf, shape=(k, N_FFT),
                                                 strides=(self.buf.strides[0] * HOP, self.buf.strides[0]))
        for s0 in range(0, k, BLOCK):
            self._block(frames[s0:s0 + BLOCK])
        self.buf = self.buf[k * HOP:].copy()

    def _block(self, frames):
        spec = np.abs(np.fft.rfft(frames * self.win, axis=1)).astype(np.float32) ** 2
        mel = np.log1p(1000.0 * (spec @ self.Wt))
        if self.prev is None:
            self.prev = mel[:1]
        d = np.maximum(np.diff(np.concatenate([self.prev, mel], 0), axis=0), 0)
        self.prev = mel[-1:]
        o = self.out
        o["flux"].append(d.sum(1)); o["lflux"].append(d[:, self.lowmel].sum(1))
        o["sub"].append(spec[:, self.sub_b].sum(1)); o["hi"].append(spec[:, self.hi_b].sum(1)); o["tot"].append(spec.sum(1))

    def done(self) -> Features:
        cat = lambda k: np.concatenate(self.out[k]).astype(np.float32) if self.out[k] else np.zeros(0, np.float32)
        rms = np.concatenate(self.rms) if self.rms else np.zeros(0)
        return Features(_onset(cat("flux")), _onset(cat("lflux")), cat("sub"), cat("hi"), cat("tot"),
                        rms.astype(np.float32), self.n, self.sr)


def feed(stream, sr: int = SR) -> Features:
    """Features from s16le mono on a binary file object, read BLOCK*HOP samples
    at a time: a 20 minute track never sits in memory whole."""
    ft = _Featurer(sr)
    want, odd = BLOCK * HOP * 2, b""
    while True:
        chunk = stream.read(want)
        if not chunk:
            break
        chunk = odd + chunk
        cut = len(chunk) & ~1
        odd = chunk[cut:]
        if cut:
            ft.push(np.frombuffer(chunk[:cut], dtype="<i2").astype(np.float32) / 32768.0)
    return ft.done()


def features(x, sr: int = SR) -> Features:
    """Test convenience: features of a float (-1..1) or int16 signal in memory."""
    x = np.asarray(x)
    if x.dtype != np.int16:
        x = np.clip(np.round(x * 32767.0), -32768, 32767).astype(np.int16)
    return feed(io.BytesIO(x.astype("<i2").tobytes()), sr)


# ---- tempo, beats, bars -----------------------------------------------------

def _smooth(env):
    return np.convolve(env, np.hanning(5).astype(np.float32), mode="same") if env.size else env


def tempo(env, fr: float, bpm_hint: float = 0.0):
    """(bpm, autocorrelation peak 0..1, beat period in frames)."""
    e = _smooth(env)
    lo, hi = int(fr * 60 / BPM_HI), int(np.ceil(fr * 60 / BPM_LO))
    if e.size < hi + 2:
        return 120.0, 0.0, fr * 0.5
    e = e - e.mean()
    n = 1 << int(np.ceil(np.log2(2 * e.size)))
    F = np.fft.rfft(e, n)
    ac = np.fft.irfft(F * np.conj(F), n)[: e.size]
    ac /= ac[0] + 1e-9
    lags = np.arange(lo, hi + 1)
    seg = ac[lo:hi + 1]
    prior = np.exp(-0.5 * np.log2((60.0 * fr / lags) / 120.0) ** 2)
    i = int(np.argmax(seg * prior))
    lag = float(lags[i])
    if 0 < i < seg.size - 1:
        a, b, c = seg[i - 1], seg[i], seg[i + 1]
        den = a - 2 * b + c
        if den < 0:
            lag += 0.5 * (a - c) / den
    bpm, peak = 60.0 * fr / lag, float(max(0.0, seg[i]))
    if bpm_hint and bpm_hint > 0:
        # TIDAL knows the tempo; the autocorrelation knows the octave less well.
        for k in (1.0, 0.5, 2.0):
            if abs(bpm * k / bpm_hint - 1) < 0.04:
                bpm, lag = bpm * k, lag / k
                break
    return float(bpm), peak, float(lag)


def track_beats(env, lag: float, tightness: float = TIGHTNESS):
    """Ellis (2007): the beat frames maximising onset strength minus a penalty
    on every interval's log-distance from the period."""
    e = _smooth(env).astype(np.float64)
    n = e.size
    if n == 0 or lag <= 0:
        return np.zeros(0, np.int64)
    lo, hi = max(1, int(round(lag * 0.5))), max(2, int(round(lag * 2.0)))
    pen = -tightness * np.log(np.arange(lo, hi + 1) / lag) ** 2
    score = np.zeros(n)
    back = np.full(n, -1, dtype=np.int64)
    for i in range(n):
        j1 = i - lo
        if j1 < 0:
            score[i] = e[i]
            continue
        a = max(0, i - hi)
        cand = score[a:j1 + 1] + pen[(i - np.arange(a, j1 + 1)) - lo]
        k = int(np.argmax(cand))
        score[i] = e[i] + cand[k]
        back[i] = a + k
    tail = np.arange(max(0, n - int(lag * 1.5)), n)
    i = int(tail[np.argmax(score[tail])])
    out = []
    while i >= 0:
        out.append(i)
        i = int(back[i])
    return np.array(out[::-1], dtype=np.int64)


def _seg_mean(v, starts, ends):
    c = np.concatenate([[0.0], np.cumsum(v, dtype=np.float64)])
    ends = np.maximum(ends, starts + 1)
    ends = np.minimum(ends, v.size)
    starts = np.minimum(starts, np.maximum(ends - 1, 0))
    return (c[ends] - c[starts]) / np.maximum(1, ends - starts)


def beat_tables(beats_idx, f: Features, lag: float) -> dict:
    """Per beat: energy, sub and high band in dB, the low onset at the beat, and
    that onset against the track's loud beats (0..1)."""
    bt = np.asarray(beats_idx, dtype=np.int64)
    if bt.size == 0:
        z = np.zeros(0)
        return {"bE": z, "bS": z, "bH": z, "bOn": z, "strength": z}
    ends = np.concatenate([bt[1:], [bt[-1] + max(1, int(lag))]])
    db = lambda v: 10 * np.log10(_seg_mean(v, bt, ends) + 1e-12)
    L = f.lenv
    bOn = np.array([L[max(0, i - 1): i + 2].max() if L.size else 0.0 for i in bt])
    p95 = np.percentile(bOn, 95) if bOn.size else 0.0
    return {"bE": db(f.tot), "bS": db(f.sub), "bH": db(f.hi), "bOn": bOn,
            "strength": np.clip(bOn / (p95 + 1e-9), 0, 1) if p95 > 0 else np.zeros(bt.size)}


def downbeat_slot(bOn, bS, bE, lo: int = 0, hi: int | None = None) -> int:
    """Which of four beats is beat 1 over [lo, hi): heaviest low onset plus the
    most spectral change against the beat before."""
    hi = len(bOn) if hi is None else hi
    if hi - lo < 1:
        return 0
    nov = np.zeros(len(bOn))
    nov[1:] = np.abs(np.diff(bS)) / 6 + np.abs(np.diff(bE)) / 6
    acc = (np.asarray(bOn) + np.minimum(nov, 1.0))[lo:hi]
    return int(np.argmax([acc[s::4].sum() for s in range(4)]))


def _per_bar(v, bars_idx, stop):
    return np.array([np.mean(v[i:min(i + 4, stop)]) if min(i + 4, stop) > i else v[i] for i in bars_idx]) \
        if len(bars_idx) else np.zeros(0)


def find_drops(E, S, Eref) -> list[dict]:
    """Bars where the full band comes back: energy over the bars before the
    riser, sub over the four before (their max, so a riff that drops its sub
    every other bar is not a drop every other bar)."""
    nbar = len(E)
    if nbar < 7:
        return []
    Sref = float(np.percentile(S, 90))
    cands = []
    for b in range(5, nbar - 1):
        dE = float(E[b] - np.max(E[b - 5:b - 1]))     # skip b-1: the riser's own peak sits there
        dS = float(S[b] - np.max(S[b - 4:b]))
        if dE >= DROP_DE_MIN and dS >= DROP_DS_MIN and E[b] >= Eref - 3:
            sc = 0.5 * float(np.clip((dE - 2) / 6, 0, 1)) + 0.5 * float(np.clip((dS - 5) / 12, 0, 1))
            cands.append((b, sc, dE, dS))
    out, i = [], 0
    while i < len(cands):
        j = i
        while j + 1 < len(cands) and cands[j + 1][0] - cands[i][0] < DROP_SPACING_BARS:
            j += 1
        grp = cands[i:j + 1]
        best = max(c[1] for c in grp)
        b, _, dE, dS = next(c for c in grp if c[1] >= 0.6 * best)
        kind = "return" if S[b - 2] < Sref - 8 and S[b - 1] < Sref - 8 else "slam"
        out.append({"bar": int(b), "strength": round(best, 2), "dE": round(dE, 1), "dS": round(dS, 1), "kind": kind})
        i = j + 1
    return out


def builds_for(drops, nbar: int) -> list[tuple[int, int]]:
    out, prev = [], None
    for d in drops:
        b = d["bar"]
        start = b - BUILD_BARS
        if prev is not None:
            start = max(start, prev + DROP_SECTION_BARS)
        start = max(0, min(start, b - 2))
        out.append((start, b))
        prev = b
    return out


def sections_for(E, S, Eref, Sref, drops, builds, nbar: int) -> list[int]:
    if nbar == 0:
        return []
    E2 = np.array([E[b:b + 2].max() for b in range(nbar)])
    S2 = np.array([S[b:b + 2].max() for b in range(nbar)])
    codes = [4] * nbar
    b = 0
    while b < min(32, nbar) and E2[b] < Eref - 6:
        codes[b] = 0
        b += 1
    for b in range(nbar):
        if codes[b] == 4 and S2[b] < Sref - 8 and E2[b] < Eref - 2:
            codes[b] = 3
    for s, e in builds:
        for b in range(s, e):
            codes[b] = 1
    for d in drops:
        for b in range(d["bar"], min(nbar, d["bar"] + DROP_SECTION_BARS)):
            codes[b] = 2
    b = 1
    while b < nbar:          # a run under 2 bars (not a build or a drop) joins the one before
        e = b
        while e < nbar and codes[e] == codes[b]:
            e += 1
        if e - b < 2 and codes[b] not in (1, 2):
            for k in range(b, e):
                codes[k] = codes[b - 1]
        b = e
    return codes


def energy_curve(rms_s) -> list[float]:
    if not len(rms_s):
        return []
    p = float(np.percentile(rms_s, 95))
    if p <= 1e-6:
        return [0.0] * len(rms_s)
    return [round(float(v), 2) for v in np.clip(rms_s / p, 0, 1)]


def confidence(ac_peak: float, bOn, lenv_nonzero_median: float) -> float:
    if not len(bOn) or not lenv_nonzero_median > 0:
        return 0.0
    align = float(np.mean(np.asarray(bOn) > lenv_nonzero_median))
    return float(np.clip(ac_peak * 2, 0, 1) * np.clip((align - 0.3) / 0.4, 0, 1))


def analyse(f: Features, duration: float, bpm_hint: float = 0.0) -> dict:
    """The map (without key/id/provider/v/at/ms, which the manager adds)."""
    dur = f.duration if f.n_samples else float(duration or 0)
    fr = f.fr
    bpm, ac, lag = tempo(f.env, fr, bpm_hint)
    bt = track_beats(f.env, lag)
    beats = bt * HOP / f.sr
    T = beat_tables(bt, f, lag)
    nb = bt.size
    bOn, bE, bS, bH = T["bOn"], T["bE"], T["bS"], T["bH"]

    # A first bar grid for finding the drops, then the real one: beat 1 from
    # the downbeat slot up to the first drop, and from each drop's own beat on.
    slot = downbeat_slot(bOn, bS, bE) if nb else 0
    first = np.arange(slot, nb, 4)
    E0, S0 = _per_bar(bE, first, nb), _per_bar(bS, first, nb)
    drops0 = find_drops(E0, S0, float(np.percentile(E0, 90))) if E0.size else []
    anchors = [int(first[d["bar"]]) for d in drops0]
    edges = [0] + anchors + [nb]
    bars_idx = []
    for k in range(len(edges) - 1):
        lo, hi = edges[k], edges[k + 1]
        s = downbeat_slot(bOn, bS, bE, lo, hi) if k == 0 else 0
        bars_idx.extend(range(lo + s, hi, 4))
    bars_idx = np.array(bars_idx, dtype=np.int64)
    nbar = bars_idx.size
    E, S = _per_bar(bE, bars_idx, nb), _per_bar(bS, bars_idx, nb)
    Eref = float(np.percentile(E, 90)) if nbar else 0.0
    Sref = float(np.percentile(S, 90)) if nbar else 0.0
    where = {int(v): i for i, v in enumerate(bars_idx)}
    drops = [dict(d, bar=where[a]) for d, a in zip(drops0, anchors) if a in where]
    builds = builds_for(drops, nbar)
    codes = sections_for(E, S, Eref, Sref, drops, builds, nbar)

    bar_t = lambda b: float(beats[bars_idx[b]])
    sections = []
    for b, c in enumerate(codes):
        if sections and sections[-1]["code"] == c:
            continue
        start = 0.0 if not sections else round(bar_t(b), 3)
        if sections:
            sections[-1]["end"] = start
        sections.append({"start": start, "end": round(dur, 3), "code": c})
    if not sections:
        sections = [{"start": 0.0, "end": round(dur, 3), "code": 0}]

    nz = f.lenv[f.lenv > 0]
    return {"state": "ready", "duration": round(dur, 3), "bpm": round(bpm, 2),
            "confidence": round(confidence(ac, bOn, float(np.median(nz)) if nz.size else 0.0), 2),
            "sr": f.sr, "hop": HOP,
            "beats": [round(float(t), 3) for t in beats],
            "strength": [round(float(s), 2) for s in T["strength"]],
            "bars": [round(float(beats[i]), 3) for i in bars_idx],
            "drops": [{"t": round(bar_t(d["bar"]), 3), "strength": d["strength"], "kind": d["kind"]} for d in drops],
            "builds": [{"start": round(bar_t(s), 3), "peak": round(bar_t(e), 3)} for s, e in builds],
            "sections": sections,
            "energy": energy_curve(f.rms_s)[: int(dur)]}


# ---- the worker -------------------------------------------------------------

_child = None


def decode(job: dict) -> Features:
    global _child
    dur = float(job.get("duration") or 0)
    limit = min(600.0, 90.0 + 2 * dur)
    cmd = ffmpeg_cmd(job.get("ffmpeg") or "ffmpeg", job["source"], bool(job.get("dash")),
                     job.get("maxSeconds") or MAX_SECONDS)
    try:
        proc = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                creationflags=IDLE_FLAGS)
    except OSError as e:
        raise DecodeError(f"ffmpeg: {e.strerror or e}") from None
    _child = proc
    if WINDOWS:
        try:
            from .system import tie_to_daemon
            tie_to_daemon(proc.pid)      # this worker's own kill-on-close job: killing us kills ffmpeg
        except Exception:
            pass
    tail = [b""]

    def drain():
        for line in proc.stderr:
            tail[0] = (tail[0] + line)[-400:]

    timed_out = threading.Event()

    def watchdog():
        timed_out.set()
        proc.kill()

    t_err = threading.Thread(target=drain, daemon=True)
    t_err.start()
    dog = threading.Timer(limit, watchdog)
    dog.daemon = True
    dog.start()
    try:
        f = feed(proc.stdout)
        rc = proc.wait()
    finally:
        dog.cancel()
        if proc.poll() is None:
            proc.kill()
    t_err.join(2)
    if timed_out.is_set():
        raise DecodeError("timeout")
    if rc != 0:
        lines = tail[0].decode("utf-8", "replace").strip().splitlines()
        raise DecodeError(redact(lines[-1] if lines else f"ffmpeg exit {rc}")[:200])
    if f.n_samples < 2 * SR:
        raise DecodeError("short")
    return f


def _quiet():
    """Idle priority for this process (ffmpeg inherits it), and on Linux a
    SIGTERM that takes ffmpeg down with us."""
    if WINDOWS:
        try:
            import ctypes
            k = ctypes.windll.kernel32
            k.SetPriorityClass(k.GetCurrentProcess(), 0x40)
        except Exception:
            pass
    else:
        try:
            os.nice(19)
        except OSError:
            pass

    def bye(*_):
        if _child is not None and _child.poll() is None:
            _child.kill()
        os._exit(3)
    for s in (signal.SIGTERM, signal.SIGINT):
        try:
            signal.signal(s, bye)
        except (ValueError, OSError):
            pass


def _say(obj) -> None:
    sys.stdout.write(json.dumps(obj, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def main(argv=None) -> int:
    try:
        job = json.loads(sys.stdin.readline() or "{}")
        ok = isinstance(job, dict) and ("source" in job or "pcm" in job) and float(job.get("duration") or 0) > 0
    except (ValueError, TypeError):
        ok = False
    if not ok:
        _say({"state": "failed", "error": "bad job"})
        return 4
    if np is None:
        _say({"state": "failed", "error": "numpy missing"})
        return 3
    _quiet()
    try:
        if "source" in job:
            f = decode(job)
        else:
            with open(job["pcm"], "rb") as fh:
                f = feed(fh)
        _say(analyse(f, float(job["duration"]), float(job.get("bpm") or 0)))
        return 0
    except DecodeError as e:
        _say({"state": "failed", "error": redact(str(e))[:200]})
        return 2
    except OSError as e:
        _say({"state": "failed", "error": redact(str(e.strerror or e))[:200]})
        return 2


if __name__ == "__main__":
    sys.exit(main())
