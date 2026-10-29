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

# Linux uses Super+Shift+M, but Windows keeps Win+Shift+M for itself (restore
# minimised windows). Win+Alt is the free corner of the Win key on Windows 10 and 11.
HOTKEYS = [
    ("Win+Alt+M", MOD_WIN | MOD_ALT, ord("M"), "library"),
    ("Win+Alt+V", MOD_WIN | MOD_ALT, ord("V"), "toggle"),
    ("Win+Alt+P", MOD_WIN | MOD_ALT, ord("P"), "miniPlayer"),
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
        for i, (label, mods, vk, _) in enumerate(HOTKEYS, start=1):
            if ctypes.windll.user32.RegisterHotKey(None, i, mods | MOD_NOREPEAT, vk):
                self.active.append(label)
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
