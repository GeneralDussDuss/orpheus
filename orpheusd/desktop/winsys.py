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
]


class Hotkeys(QAbstractNativeEventFilter):
    """Registers HOTKEYS system-wide and calls `on_fire(method)` when one is pressed."""

    def __init__(self, on_fire):
        super().__init__()
        self.on_fire = on_fire
        self.active: list[str] = []
        self.failed: list[str] = []
        if not WINDOWS:
            return
        bound = set()
        for i, (label, mods, vk, action) in enumerate(HOTKEYS, start=1):
            if action in bound:
                continue
            if ctypes.windll.user32.RegisterHotKey(None, i, mods | MOD_NOREPEAT, vk):
                self.active.append(label)
                bound.add(action)
            else:  # another app owns the combination
                self.failed.append(label)

    def nativeEventFilter(self, event_type, message):
        if event_type == b"windows_generic_MSG":
            msg = wintypes.MSG.from_address(int(message))
            if msg.message == WM_HOTKEY and 1 <= msg.wParam <= len(HOTKEYS):
                self.on_fire(HOTKEYS[msg.wParam - 1][3])
                return True, 0
        return False, 0

    def release(self):
        if WINDOWS:
            for i in range(1, len(HOTKEYS) + 1):
                ctypes.windll.user32.UnregisterHotKey(None, i)


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
