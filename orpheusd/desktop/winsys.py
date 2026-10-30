"""The Windows-only parts of the desktop app: global hotkeys and starting at sign-in.

Both are plain Win32 through ctypes and the registry, so nothing beyond the
standard library is needed. Off Windows every function here is a quiet no-op.
"""
from __future__ import annotations

import ctypes
import sys
from ctypes import wintypes

from PySide6.QtCore import QAbstractNativeEventFilter

WINDOWS = sys.platform == "win32"

MOD_ALT, MOD_CONTROL, MOD_SHIFT, MOD_WIN, MOD_NOREPEAT = 0x1, 0x2, 0x4, 0x8, 0x4000
WM_HOTKEY = 0x0312
VK_SPACE, VK_LEFT, VK_RIGHT, VK_OEM_PLUS, VK_OEM_MINUS = 0x20, 0x25, 0x27, 0xBB, 0xBD
VK_OEM_COMMA, VK_OEM_PERIOD = 0xBC, 0xBE
WIN_ALT = MOD_WIN | MOD_ALT

# Linux uses Super+Shift+M, but Windows keeps Win+Shift+M for itself (restore
# minimised windows). Win+Alt is the free corner of the Win key on Windows 10 and 11.
# A plain action is a QML IPC method; "control:x" and "volume:±n" go to orpheusd.
# Rows sharing an action are alternates: the first that registers wins, so a
# combination another app already owns falls through to the next.
HOTKEYS = [
    ("Win+Alt+M", WIN_ALT, ord("M"), "library"),
    ("Win+Alt+O", WIN_ALT, ord("O"), "library"),
    ("Win+Alt+V", WIN_ALT, ord("V"), "toggle"),
    ("Win+Alt+P", WIN_ALT, ord("P"), "miniPlayer"),
    ("Win+Alt+W", WIN_ALT, ord("W"), "widget:toggle"),
    ("Win+Alt+H", WIN_ALT, ord("H"), "widget:toggle"),
    ("Win+Alt+J", WIN_ALT, ord("J"), "widget:toggle"),
    ("Win+Alt+E", WIN_ALT, ord("E"), "eq"),
    ("Win+Alt+L", WIN_ALT, ord("L"), "lyrics"),
    ("Win+Alt+Space", WIN_ALT, VK_SPACE, "control:toggle"),
    ("Win+Alt+Right", WIN_ALT, VK_RIGHT, "control:next"),
    ("Win+Alt+.", WIN_ALT, VK_OEM_PERIOD, "control:next"),
    ("Win+Alt+Left", WIN_ALT, VK_LEFT, "control:previous"),
    ("Win+Alt+,", WIN_ALT, VK_OEM_COMMA, "control:previous"),
    ("Win+Alt+T", WIN_ALT, ord("T"), "theme:next"),
    ("Win+Alt+C", WIN_ALT, ord("C"), "theme:next"),
    ("Win+Alt+Y", WIN_ALT, ord("Y"), "theme:next"),
    ("Win+Alt+=", WIN_ALT, VK_OEM_PLUS, "volume:+5"),
    ("Win+Alt+-", WIN_ALT, VK_OEM_MINUS, "volume:-5"),
    # The in-game HUD; R, G, B and PrtScn under Win+Alt belong to the Game Bar.
    ("Win+Alt+N", WIN_ALT, ord("N"), "hud:show"),
    ("Win+Alt+I", WIN_ALT, ord("I"), "hud:show"),
    ("Win+Alt+U", WIN_ALT, ord("U"), "hud:show"),
]


# What each action is called wherever a person reads it (settings, cheat sheet).
ACTION_LABELS = {
    "library": "show/hide the player",
    "toggle": "show/hide the visualizer",
    "miniPlayer": "mini player on/off",
    "widget:toggle": "show/hide the widget",
    "eq": "open the equalizer",
    "lyrics": "open the lyrics",
    "control:toggle": "play / pause",
    "control:next": "next track",
    "control:previous": "previous track",
    "theme:next": "next theme",
    "volume:+5": "volume up",
    "volume:-5": "volume down",
    "hud:show": "show the in-game HUD",
}

MODS = {"win": MOD_WIN, "super": MOD_WIN, "meta": MOD_WIN, "alt": MOD_ALT,
        "ctrl": MOD_CONTROL, "control": MOD_CONTROL, "shift": MOD_SHIFT}
MOD_ORDER = ((MOD_WIN, "Win"), (MOD_CONTROL, "Ctrl"), (MOD_ALT, "Alt"), (MOD_SHIFT, "Shift"))
KEYS = {"space": VK_SPACE, "left": VK_LEFT, "right": VK_RIGHT, "up": 0x26, "down": 0x28,
        "home": 0x24, "end": 0x23, "pgup": 0x21, "pageup": 0x21, "pgdn": 0x22, "pagedown": 0x22,
        "insert": 0x2D, "ins": 0x2D, "delete": 0x2E, "del": 0x2E, "backspace": 0x08,
        "enter": 0x0D, "return": 0x0D, "tab": 0x09, "esc": 0x1B, "escape": 0x1B,
        "pause": 0x13, "print": 0x2C, "printscreen": 0x2C,
        "=": VK_OEM_PLUS, "+": VK_OEM_PLUS, "-": VK_OEM_MINUS, ",": VK_OEM_COMMA, ".": VK_OEM_PERIOD,
        ";": 0xBA, "/": 0xBF, "`": 0xC0, "[": 0xDB, "\\": 0xDC, "]": 0xDD, "'": 0xDE,
        "mediaplaypause": 0xB3, "playpause": 0xB3, "medianext": 0xB0, "mediaprev": 0xB1,
        "mediaprevious": 0xB1, "mediastop": 0xB2, "volumeup": 0xAF, "volumedown": 0xAE,
        "volumemute": 0xAD}
KEY_NAMES = {VK_SPACE: "Space", VK_LEFT: "Left", VK_RIGHT: "Right", 0x26: "Up", 0x28: "Down",
             0x24: "Home", 0x23: "End", 0x21: "PgUp", 0x22: "PgDn", 0x2D: "Insert", 0x2E: "Delete",
             0x08: "Backspace", 0x0D: "Enter", 0x09: "Tab", 0x1B: "Esc", 0x13: "Pause", 0x2C: "Print",
             VK_OEM_PLUS: "=", VK_OEM_MINUS: "-", VK_OEM_COMMA: ",", VK_OEM_PERIOD: ".",
             0xBA: ";", 0xBF: "/", 0xC0: "`", 0xDB: "[", 0xDC: "\\", 0xDD: "]", 0xDE: "'",
             0xB3: "MediaPlayPause", 0xB0: "MediaNext", 0xB1: "MediaPrev", 0xB2: "MediaStop",
             0xAF: "VolumeUp", 0xAE: "VolumeDown", 0xAD: "VolumeMute"}
for _i in range(1, 25):
    KEYS[f"f{_i}"] = 0x6F + _i
    KEY_NAMES[0x6F + _i] = f"F{_i}"
for _i in range(10):
    KEYS[f"num{_i}"] = 0x60 + _i
    KEY_NAMES[0x60 + _i] = f"Num{_i}"
# Keys nobody types with, so they may stand alone: media keys and F13-F24.
STANDALONE = {0xB3, 0xB0, 0xB1, 0xB2, 0xAF, 0xAE, 0xAD} | set(range(0x7C, 0x88))


def parse_combo(text: str) -> tuple[int, int]:
    """"Win+Alt+H" -> (mods, vk). Raises ValueError saying what is wrong."""
    s = str(text or "").strip()
    if not s:
        raise ValueError("empty")
    if s == "+" or s.endswith("++"):          # "Win+Alt++": the key is +
        parts = s[:-2].split("+") + ["+"] if s != "+" else ["+"]
    else:
        parts = s.split("+")
    parts = [p.strip() for p in parts]
    if any(not p for p in parts):
        raise ValueError(f"cannot read {s!r}")
    *mod_parts, key = parts
    mods = 0
    for m in mod_parts:
        bit = MODS.get(m.lower())
        if bit is None:
            raise ValueError(f"unknown modifier {m!r} (Win, Ctrl, Alt, Shift)")
        mods |= bit
    k = key.lower()
    if len(key) == 1 and key.isascii() and key.isalnum():
        vk = ord(key.upper())
    elif k in KEYS:
        vk = KEYS[k]
    else:
        raise ValueError(f"unknown key {key!r}")
    if not mods & (MOD_WIN | MOD_CONTROL | MOD_ALT) and vk not in STANDALONE:
        raise ValueError("needs Win, Ctrl or Alt, or it would eat ordinary typing")
    return mods, vk


def format_combo(mods: int, vk: int) -> str:
    name = KEY_NAMES.get(vk) or (chr(vk) if 0x30 <= vk <= 0x5A else f"0x{vk:02X}")
    return "+".join([n for bit, n in MOD_ORDER if mods & bit] + [name])


def normalize(text: str) -> str:
    return format_combo(*parse_combo(text))


def plan(overrides: dict | None = None) -> list[tuple[str, list[tuple[str, str]]]]:
    """Each action with the combinations to try, in order, and where each came from.

    `overrides` is config.json's `hotkeys`: {action: combo | [combo, ...] | "" | null}.
    An override goes first and the built-in alternates stay behind it, so a combo
    another app owns does not cost the action its key. "" or null switches it off."""
    overrides = overrides if isinstance(overrides, dict) else {}
    out: dict[str, list[tuple[str, str]]] = {}
    for label, _, _, action in HOTKEYS:
        out.setdefault(action, []).append((label, "default"))
    for action, want in overrides.items():
        if action not in out:
            continue  # reported by Hotkeys.register
        if want is None or want == "" or want == "none" or want == []:
            out[action] = []
            continue
        mine = [want] if isinstance(want, str) else [str(w) for w in want]
        rest = [c for c in out[action] if c[0] not in mine]
        out[action] = [(c, "config") for c in mine] + rest
    return list(out.items())


ERROR_HOTKEY_ALREADY_REGISTERED = 1409


class Hotkeys(QAbstractNativeEventFilter):
    """Registers HOTKEYS system-wide (config.json overrides on top) and calls
    `on_fire(method)` when one is pressed. Call `register()` again to rebind live.

    `status` holds one row per action for the settings page and the cheat sheet:
    {action, label, combo (the one that won, or ""), state: active|failed|off,
     tried: [{combo, source, ok, reason}]}."""

    def __init__(self, on_fire, overrides: dict | None = None):
        super().__init__()
        self.on_fire = on_fire
        self.active: list[str] = []
        self.failed: list[str] = []
        self.status: list[dict] = []
        self.overrides: dict = {}
        self.listeners: list = []           # called with no arguments after each register()
        self._ids: dict[int, str] = {}
        self._next_id = 1
        self.register(overrides)

    def _try(self, mods: int, vk: int) -> tuple[int, str]:
        """(id, "") on success, (0, why) when Windows says no."""
        if not WINDOWS:
            return 0, "global hotkeys are Windows-only here"
        user32 = ctypes.WinDLL("user32", use_last_error=True)
        hid = self._next_id
        self._next_id = self._next_id % 0xBFFF + 1   # application ids live in 1..0xBFFF
        if user32.RegisterHotKey(None, hid, mods | MOD_NOREPEAT, vk):
            return hid, ""
        err = ctypes.get_last_error()
        if err == ERROR_HOTKEY_ALREADY_REGISTERED:
            return 0, "taken by another app or by Windows"
        return 0, f"Windows refused it (error {err})"

    def register(self, overrides: dict | None = None):
        self.release()
        self.overrides = dict(overrides) if isinstance(overrides, dict) else {}
        self.active, self.failed, self.status = [], [], []
        used: dict[tuple[int, int], str] = {}
        for action, combos in plan(self.overrides):
            row = {"action": action, "label": ACTION_LABELS.get(action, action),
                   "combo": "", "state": "failed" if combos else "off", "tried": []}
            for combo, source in combos:
                t = {"combo": combo, "source": source, "ok": False, "reason": ""}
                row["tried"].append(t)
                if row["combo"]:
                    t["reason"] = "spare"     # an earlier one already won
                    continue
                try:
                    mods, vk = parse_combo(combo)
                    t["combo"] = combo = format_combo(mods, vk)
                except ValueError as e:
                    t["reason"] = str(e)
                    self.failed.append(combo)
                    continue
                if (mods, vk) in used:
                    other = used[(mods, vk)]
                    t["reason"] = "already bound to " + ACTION_LABELS.get(other, other)
                    self.failed.append(combo)
                    continue
                hid, why = self._try(mods, vk)
                if hid:
                    self._ids[hid] = action
                    used[(mods, vk)] = action
                    t["ok"] = True
                    row["combo"], row["state"] = combo, "active"
                    self.active.append(combo)
                else:
                    t["reason"] = why
                    self.failed.append(combo)
            self.status.append(row)
        for action, want in self.overrides.items():
            if action not in ACTION_LABELS:
                self.status.append({"action": action, "label": action, "combo": "", "state": "failed",
                                    "tried": [{"combo": str(want), "source": "config",
                                               "ok": False, "reason": "unknown action"}]})
        for f in list(self.listeners):
            f()

    def nativeEventFilter(self, event_type, message):
        if event_type == b"windows_generic_MSG":
            msg = wintypes.MSG.from_address(int(message))
            if msg.message == WM_HOTKEY and msg.wParam in self._ids:
                self.on_fire(self._ids[msg.wParam])
                return True, 0
        return False, 0

    def release(self):
        if WINDOWS:
            for hid in self._ids:
                ctypes.windll.user32.UnregisterHotKey(None, hid)
        self._ids = {}


RUN_KEY = r"Software\Microsoft\Windows\CurrentVersion\Run"


def starts_with_windows() -> bool:
    if not WINDOWS:
        return False
    import winreg
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_KEY) as k:
            winreg.QueryValueEx(k, "Orpheus")
        return True
    except OSError:
        return False


def set_start_with_windows(on: bool):
    """At sign-in, start quietly in the tray: no window until it is asked for."""
    if not WINDOWS:
        return
    import winreg
    pythonw = sys.executable.replace("python.exe", "pythonw.exe")
    with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_KEY, 0, winreg.KEY_SET_VALUE) as k:
        if on:
            winreg.SetValueEx(k, "Orpheus", 0, winreg.REG_SZ,
                              f'"{pythonw}" -m orpheusd.desktop --open none')
        else:
            try:
                winreg.DeleteValue(k, "Orpheus")
            except OSError:
                pass


def own_child(pid: int) -> bool:
    """Put a child of the app (the daemon, cava, audiocap) in a kill-on-close
    job, so it ends with the app however the app ends: a crash or Task Manager
    used to leave cava.exe and a playing daemon behind. The venv launcher that
    starts a Python child keeps that child in its own kill-on-close job, so
    ending the launcher ends the real interpreter too. Off Windows: nothing."""
    if not WINDOWS or not pid:
        return False
    from orpheusd.system import tie_to_daemon   # the same job object, held by this process
    try:
        tie_to_daemon(pid)
        return True
    except OSError as e:
        print(f"orpheus-desktop: pid {pid} could outlive the app: {e}", file=sys.stderr)
        return False
