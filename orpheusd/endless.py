"""Endless play: when the queue runs out, carry on with TIDAL's radio for the
last track, picked and ordered so it flows rather than lurches.

TIDAL's track radio comes back in relevance order. From it we drop what was
heard lately or is already queued (by id, and by title + artist, since the
same recording appears on several releases), take the most relevant of the
rest, and order those as a chain: each next track is the closest in energy to
the one before. Energy is BPM where TIDAL has it, folded so a half- or
double-time track counts as close; where it has none, popularity and length
stand in, which keeps hits next to hits and long tracks next to long ones.
The same artist twice in a row costs extra, so the chain spreads them out.
"""

import re


def _norm(s: str) -> str:
    s = re.sub(r"\(.*?\)|\[.*?\]", "", (s or "").lower())
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def _sig(t: dict) -> tuple:
    return (_norm(t.get("title", "")), _norm((t.get("artists") or [""])[0]))


def bpm_distance(a: float, b: float) -> float:
    """Relative tempo distance, treating half and double time as the same feel."""
    if not a or not b:
        return 1.0
    return min(abs(a - b), abs(a - 2 * b), abs(2 * a - b)) / max(a, b)


def pick(seed: dict, radio: list[dict], recent: set[str], queued: list[dict], n: int = 20) -> list[dict]:
    seen_ids = {str(t.get("id")) for t in queued} | {str(i) for i in recent}
    seen_sig = {_sig(t) for t in queued}
    cand = []
    for t in radio:
        if not t.get("available", True) or str(t.get("id")) in seen_ids or _sig(t) in seen_sig:
            continue
        seen_ids.add(str(t.get("id")))
        seen_sig.add(_sig(t))
        cand.append(t)
    if len(cand) < n // 2:
        # A small radio and a long history: let older history back in rather
        # than stopping, but still never what is in the queue right now.
        queued_ids = {str(t.get("id")) for t in queued}
        extra = [t for t in radio if str(t.get("id")) not in queued_ids and t not in cand
                 and _sig(t) not in {_sig(q) for q in queued}]
        cand += extra[: n - len(cand)]
    cand = cand[: max(n, int(n * 1.5))]       # relevance first: TIDAL's order
    return order(seed, cand)[:n]


def order(seed: dict, tracks: list[dict]) -> list[dict]:
    if not tracks:
        return []
    have_bpm = sum(1 for t in tracks if t.get("bpm")) >= len(tracks) * 0.6 and seed.get("bpm")
    pops = [t.get("popularity") or 0 for t in tracks] + [seed.get("popularity") or 0]
    durs = [t.get("duration") or 0 for t in tracks] + [seed.get("duration") or 0]
    pspan = max(1, max(pops) - min(pops))
    dspan = max(1, max(durs) - min(durs))

    def dist(a: dict, b: dict) -> float:
        if have_bpm:
            d = bpm_distance(float(a.get("bpm") or 0), float(b.get("bpm") or 0)) * 4
            d += abs((a.get("popularity") or 0) - (b.get("popularity") or 0)) / pspan * 0.5
        else:
            d = abs((a.get("popularity") or 0) - (b.get("popularity") or 0)) / pspan
            d += abs((a.get("duration") or 0) - (b.get("duration") or 0)) / dspan * 0.5
        if (a.get("artists") or [None])[0] == (b.get("artists") or [None])[0]:
            d += 0.75
        return d

    out, rest, cur = [], list(tracks), seed
    while rest:
        # A slight pull toward the front keeps the most relevant tracks early.
        i = min(range(len(rest)), key=lambda k: dist(cur, rest[k]) + k * 0.01)
        cur = rest.pop(i)
        out.append(cur)
    return out
