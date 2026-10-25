"""MPRIS for Orpheus, so media keys, the Omarchy bar, playerctl and the
Orpheus visualizer all see and control playback like any other player."""

import logging

from dbus_next import BusType, Variant
from dbus_next.aio import MessageBus
from dbus_next.constants import PropertyAccess
from dbus_next.service import ServiceInterface, dbus_property, method, signal

log = logging.getLogger("orpheus.mpris")

OBJ = "/org/mpris/MediaPlayer2"
NO_TRACK = "/org/mpris/MediaPlayer2/TrackList/NoTrack"


class Root(ServiceInterface):
    def __init__(self, app):
        super().__init__("org.mpris.MediaPlayer2")
        self.app = app

    @method()
    def Raise(self):
        self.app.raise_ui()

    @method()
    def Quit(self):
        pass

    @dbus_property(access=PropertyAccess.READ)
    def CanQuit(self) -> "b":
        return False

    @dbus_property(access=PropertyAccess.READ)
    def CanRaise(self) -> "b":
        return True

    @dbus_property(access=PropertyAccess.READ)
    def HasTrackList(self) -> "b":
        return False

    @dbus_property(access=PropertyAccess.READ)
    def Identity(self) -> "s":
        return "Orpheus"

    @dbus_property(access=PropertyAccess.READ)
    def DesktopEntry(self) -> "s":
        return "orpheus"

    @dbus_property(access=PropertyAccess.READ)
    def SupportedUriSchemes(self) -> "as":
        return []

    @dbus_property(access=PropertyAccess.READ)
    def SupportedMimeTypes(self) -> "as":
        return []


class PlayerIface(ServiceInterface):
    def __init__(self, player):
        super().__init__("org.mpris.MediaPlayer2.Player")
        self.p = player
        self._last = {}

    # ---- helpers -------------------------------------------------------------

    def _metadata(self):
        t = self.p.current
        if not t:
            return {"mpris:trackid": Variant("o", NO_TRACK)}
        md = {
            "mpris:trackid": Variant("o", f"/org/orpheus/track/{t['id']}"),
            "mpris:length": Variant("x", int((self.p.duration or t.get("duration") or 0) * 1_000_000)),
            "xesam:title": Variant("s", t.get("title") or ""),
            "xesam:artist": Variant("as", t.get("artists") or []),
            "xesam:album": Variant("s", t.get("album") or ""),
            "xesam:url": Variant("s", f"https://tidal.com/browse/track/{t['id']}"),
        }
        if t.get("art"):
            md["mpris:artUrl"] = Variant("s", t["art"])
        return md

    def _status(self):
        if self.p.current is None:
            return "Stopped"
        return "Paused" if self.p.paused or self.p.idle else "Playing"

    def refresh(self):
        """Emit PropertiesChanged for whatever actually changed."""
        now = {
            "PlaybackStatus": self._status(),
            "Metadata": self._metadata(),
            "Volume": self.p.volume / 100.0,
            "Shuffle": self.p.shuffle,
            "LoopStatus": {"off": "None", "all": "Playlist", "one": "Track"}[self.p.repeat],
            "CanGoNext": self.p.next_pos(manual=True) >= 0,
            "CanGoPrevious": self.p.current is not None,
        }
        changed = {}
        for k, v in now.items():
            key = repr(v) if k != "Metadata" else repr({mk: mv.value for mk, mv in v.items()})
            if self._last.get(k) != key:
                self._last[k] = key
                changed[k] = v
        if changed:
            self.emit_properties_changed(changed)

    # ---- methods -------------------------------------------------------------

    @method()
    async def Next(self):
        await self.p.next()

    @method()
    async def Previous(self):
        await self.p.previous()

    @method()
    async def Pause(self):
        await self.p.set_paused(True)

    @method()
    async def PlayPause(self):
        await self.p.toggle()

    @method()
    async def Stop(self):
        await self.p.set_paused(True)

    @method()
    async def Play(self):
        await self.p.set_paused(False)

    @method()
    async def Seek(self, offset: "x"):
        await self.p.seek(self.p.position + offset / 1_000_000)
        self.Seeked(int(self.p.position * 1_000_000))

    @method()
    async def SetPosition(self, track_id: "o", position: "x"):
        await self.p.seek(position / 1_000_000)
        self.Seeked(int(self.p.position * 1_000_000))

    @method()
    def OpenUri(self, uri: "s"):
        pass

    @signal()
    def Seeked(self, position) -> "x":
        return position

    # ---- properties ----------------------------------------------------------

    @dbus_property(access=PropertyAccess.READ)
    def PlaybackStatus(self) -> "s":
        return self._status()

    @dbus_property()
    def LoopStatus(self) -> "s":
        return {"off": "None", "all": "Playlist", "one": "Track"}[self.p.repeat]

    @LoopStatus.setter
    async def LoopStatus(self, value: "s"):
        await self.p.set_repeat({"None": "off", "Playlist": "all", "Track": "one"}.get(value, "off"))

    @dbus_property()
    def Rate(self) -> "d":
        return 1.0

    @Rate.setter
    def Rate(self, value: "d"):
        pass

    @dbus_property()
    def Shuffle(self) -> "b":
        return self.p.shuffle

    @Shuffle.setter
    async def Shuffle(self, value: "b"):
        await self.p.set_shuffle(bool(value))

    @dbus_property(access=PropertyAccess.READ)
    def Metadata(self) -> "a{sv}":
        return self._metadata()

    @dbus_property()
    def Volume(self) -> "d":
        return self.p.volume / 100.0

    @Volume.setter
    async def Volume(self, value: "d"):
        await self.p.set_volume(value * 100.0)

    @dbus_property(access=PropertyAccess.READ)
    def Position(self) -> "x":
        return int(self.p.position * 1_000_000)

    @dbus_property(access=PropertyAccess.READ)
    def MinimumRate(self) -> "d":
        return 1.0

    @dbus_property(access=PropertyAccess.READ)
    def MaximumRate(self) -> "d":
        return 1.0

    @dbus_property(access=PropertyAccess.READ)
    def CanGoNext(self) -> "b":
        return self.p.next_pos(manual=True) >= 0

    @dbus_property(access=PropertyAccess.READ)
    def CanGoPrevious(self) -> "b":
        return self.p.current is not None

    @dbus_property(access=PropertyAccess.READ)
    def CanPlay(self) -> "b":
        return self.p.current is not None

    @dbus_property(access=PropertyAccess.READ)
    def CanPause(self) -> "b":
        return self.p.current is not None

    @dbus_property(access=PropertyAccess.READ)
    def CanSeek(self) -> "b":
        return self.p.current is not None

    @dbus_property(access=PropertyAccess.READ)
    def CanControl(self) -> "b":
        return True


class Mpris:
    def __init__(self, app, player):
        self.root = Root(app)
        self.iface = PlayerIface(player)
        self.bus = None

    async def start(self):
        self.bus = await MessageBus(bus_type=BusType.SESSION).connect()
        self.bus.export(OBJ, self.root)
        self.bus.export(OBJ, self.iface)
        await self.bus.request_name("org.mpris.MediaPlayer2.orpheus")
        log.info("MPRIS ready")

    def refresh(self):
        if self.bus:
            try:
                self.iface.refresh()
            except Exception as e:
                log.debug("mpris refresh failed: %s", e)
