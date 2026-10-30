"""Game mode must hold through brief dropouts instead of flapping."""
from orpheusd.desktop import gamemode as gm


def run(seq, step=2.0, **kw):
    """Feed scripted readings (True=game, False=none, Exception=probe error), `step` s apart."""
    t = [0.0]
    det = gm.Detector(api=object(), own_pid=1, config=lambda: "auto", clock=lambda: t[0], **kw)
    events = []
    det.listeners.append(events.append)
    it = iter(seq)
    orig = gm.assess

    def fake(api, pid):
        r = next(it)
        if isinstance(r, Exception):
            raise r
        return gm.Verdict(r, "fullscreen window" if r else "", monitor=(0, 0, 1920, 1080))
    gm.assess = fake
    try:
        for _ in seq:
            det.poll()
            t[0] += step
    finally:
        gm.assess = orig
    return events


def test_brief_off_does_not_flap_and_long_off_exits_once():
    seq = [True] * 3 + [False] * 2 + [True] * 3 + [False] * 8   # 4 s dropout, then 16 s gone
    assert run(seq) == [True, False]


def test_alt_tab_of_several_seconds_is_held():
    assert run([True, False, False, False, True, True]) == [True]   # 6 s < HOLD_S


def test_probe_errors_neither_enter_nor_exit():
    assert run([True] + [OSError("gone")] * 10 + [True]) == [True]


def test_config_off_exits_immediately():
    t = [0.0]
    cfg = ["auto"]
    det = gm.Detector(api=object(), own_pid=1, config=lambda: cfg[0], clock=lambda: t[0])
    ev = []
    det.listeners.append(ev.append)
    orig = gm.assess
    gm.assess = lambda a, p: gm.Verdict(True, "x", monitor=(0, 0, 10, 10))
    try:
        det.poll()
        cfg[0] = "off"
        det.poll()
    finally:
        gm.assess = orig
    assert ev == [True, False]
