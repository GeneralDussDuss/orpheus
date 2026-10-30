"""The phone remote: a small web page served by the daemon, and the opt-in LAN
listener that lets a phone reach it.

The daemon's own API listens on 127.0.0.1 only and has no authentication:
anything on the machine may drive it, nothing off it can. The remote keeps
that. Its page and its few endpoints (status, transport, volume, jump,
search, play) are served under /remote on the loopback API and, when config
`remote` is "lan", on a second listener bound to the LAN address on
`remotePort` (47838). Every remote request, the page included, needs the
pairing token: `?t=` on the page URL, which the page then sends as the
X-Orpheus-Token header. The LAN listener serves nothing else, so the full API
is never reachable from the network, token or not.

The token lives in STATE_DIR/remote.json; resetting it unpairs every phone.
The settings page shows the URL as a QR code (qr.py, no dependency).
"""

import asyncio
import hmac
import json
import logging
import os
import secrets
import socket
import sys
from pathlib import Path

from aiohttp import web

from . import qr
from .system import STATE_DIR, write_atomic

log = logging.getLogger("orpheus.remote")

WEB_DIR = Path(__file__).resolve().parent / "web"
CONTROLS = {"toggle", "play", "pause", "next", "previous", "seek", "volume", "jump", "shuffle", "repeat"}


def lan_ip() -> str:
    """The address of the interface the default route uses. Connecting a UDP
    socket sends nothing; it only makes the OS pick the source address."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("10.255.255.255", 1))
        ip = s.getsockname()[0]
    except OSError:
        ip = ""
    finally:
        s.close()
    return "" if ip.startswith("127.") or ip == "0.0.0.0" else ip


def _toml_colors(path: Path) -> dict:
    import tomllib
    try:
        with open(path, "rb") as f:
            return {k: v for k, v in tomllib.load(f).items() if isinstance(v, str)}
    except Exception:
        return {}


def theme_colors() -> dict:
    """The player's theme, so the page matches it: the desktop app's chosen
    palette on Windows, Omarchy's current one on Linux, else Orpheus' own."""
    found = {}
    themes = Path(__file__).resolve().parent / "desktop" / "themes"
    home = Path(os.environ.get("ORPHEUS_HOME") or os.environ.get("HOME") or str(Path.home()))
    try:
        name = json.loads((STATE_DIR / "desktop.json").read_text(encoding="utf-8")).get("theme", "")
    except Exception:
        name = ""
    for d in (home / ".config" / "orpheus" / "themes", themes / "orpheus", themes / "omarchy"):
        if name and (d / f"{name}.toml").is_file():
            found = _toml_colors(d / f"{name}.toml")
            break
    if not found and sys.platform != "win32":
        for p in (Path.home() / ".config/omarchy/current/theme/colors.toml",
                  Path.home() / ".local/state/omarchy/current/theme/colors.toml"):
            if p.is_file():
                found = _toml_colors(p)
                break
    # "orpheus" (the default) and "album" are not palettes on disk: Orpheus' own dark look.
    return {"background": found.get("background", "#101014"), "foreground": found.get("foreground", "#e6e6e6"),
            "accent": found.get("accent", "#7aa2f7"), "muted": found.get("muted") or found.get("dark_foreground") or "#808080",
            "mode": found.get("mode", "dark")}


class Remote:
    def __init__(self, app, config):
        self.app = app
        self.config = config
        self.path = STATE_DIR / "remote.json"
        self.token = self._load_token()
        self._runner = None
        self._bound = None          # (host, port) while the LAN listener is up
        self.error = ""

    # ---- pairing ---------------------------------------------------------------

    def _load_token(self) -> str:
        try:
            t = json.loads(self.path.read_text(encoding="utf-8")).get("token", "")
            if isinstance(t, str) and len(t) >= 16:
                return t
        except Exception:
            pass
        return self.reset_token()

    def reset_token(self) -> str:
        self.token = secrets.token_urlsafe(16)
        write_atomic(self.path, json.dumps({"token": self.token}).encode())
        return self.token

    def authorised(self, req: web.Request) -> bool:
        given = req.headers.get("X-Orpheus-Token") or req.query.get("t") or ""
        return bool(given) and hmac.compare_digest(given.encode(), self.token.encode())

    def url(self) -> str:
        host, port = self._bound or (self.config.text("remoteHost") or lan_ip() or "127.0.0.1",
                                     int(self.config.get("remotePort") or 47838))
        return f"http://{host}:{port}/remote?t={self.token}"

    def pairing(self) -> dict:
        url = self.url()
        return {"mode": self.config.remote, "listening": bool(self._bound),
                "host": self._bound[0] if self._bound else "", "port": self._bound[1] if self._bound else 0,
                "url": url if self._bound else "", "token": self.token, "error": self.error,
                "local": f"/remote?t={self.token}",
                "qr": qr.rows(url) if self._bound else []}

    def state(self) -> dict:
        return {"mode": self.config.remote, "listening": bool(self._bound),
                "url": self.url() if self._bound else "", "error": self.error}

    # ---- the LAN listener ----------------------------------------------------------

    async def sync(self):
        """Bring the LAN listener in line with config: up on `lan`, down on `off`,
        rebound when the address or port changes."""
        want = None
        if self.config.remote == "lan":
            host = self.config.text("remoteHost") or lan_ip()
            try:
                port = int(self.config.get("remotePort") or 47838)
            except (TypeError, ValueError):
                port = 47838
            if not host:
                self.error = "no LAN address found"
            else:
                want = (host, port)
        if want == self._bound:
            return
        await self.stop()
        if not want:
            return
        app = web.Application()
        self.add_routes(app)
        runner = web.AppRunner(app, access_log=None)
        await runner.setup()
        try:
            await web.TCPSite(runner, want[0], want[1]).start()
        except OSError as e:
            await runner.cleanup()
            self.error = f"could not listen on {want[0]}:{want[1]}: {e.strerror or e}"
            log.warning("remote: %s", self.error)
            self._bound = None
            return
        self._runner, self._bound, self.error = runner, want, ""
        log.info("remote listening on http://%s:%d/remote (token required)", *want)
        self.app._changed()

    async def stop(self):
        if self._runner:
            await self._runner.cleanup()
            log.info("remote listener closed")
        self._runner, self._bound = None, None

    async def loop(self):
        while True:
            try:
                await self.sync()
            except Exception as e:
                log.warning("remote sync failed: %s", e)
            await asyncio.sleep(2)

    # ---- routes (on both listeners) ----------------------------------------------------------

    def add_routes(self, webapp: web.Application):
        a, J = self.app, web.json_response

        @web.middleware
        async def gate(req, handler):
            if req.path == "/remote" or req.path.startswith("/remote/"):
                if req.path.startswith("/remote/pair"):
                    return await handler(req)   # loopback-only, see App.routes
                if not self.authorised(req):
                    if req.path == "/remote":
                        return web.Response(status=401, content_type="text/html",
                                            text="<!doctype html><meta name=viewport content='width=device-width'>"
                                                 "<body style='font:16px monospace;background:#111;color:#ccc;padding:2em'>"
                                                 "<p>orpheus ╱╱ remote</p><p>This page needs the pairing link: scan "
                                                 "the QR code in Orpheus' settings (listening ▸ phone remote).</p>")
                    return J({"error": "pairing token required"}, status=401)
            return await handler(req)

        webapp.middlewares.append(gate)

        async def page(req):
            html = (WEB_DIR / "remote.html").read_text(encoding="utf-8")
            return web.Response(text=html, content_type="text/html",
                                headers={"Cache-Control": "no-store", "Referrer-Policy": "no-referrer",
                                         "X-Frame-Options": "DENY"})

        async def status(req):
            since = req.query.get("since")
            if since is not None:
                try:
                    await a.wait_change(int(since), 20)
                except ValueError:
                    pass
            return J(self.slim_status())

        async def control(req):
            action = req.match_info["action"]
            if action not in CONTROLS:
                raise web.HTTPNotFound(text="unknown action")
            try:
                body = await req.json()
            except Exception:
                body = {}
            await a.control(action, body if isinstance(body, dict) else {})
            return J(self.slim_status())

        async def search(req):
            q = req.query.get("q", "").strip()
            if not q or not a.tidal.signed_in:
                return J({"tracks": []})
            res = await a.tidal.search(q, limit=20)
            return J({"tracks": [_slim(t) for t in res.get("tracks", [])]})

        async def play(req):
            b = await req.json()
            t = b.get("track") if isinstance(b, dict) else None
            if not isinstance(t, dict) or not t.get("id") or not a.tidal.signed_in:
                raise web.HTTPBadRequest(text="track required")
            if b.get("next"):
                await a.player.enqueue([t], next_up=True)
            else:
                tracks, ctx = await a.tracks_for({"kind": "track", "id": str(t["id"]), "track": t})
                await a.player.play_list(tracks, 0, ctx)
            return J(self.slim_status())

        async def theme(req):
            return J(theme_colors())

        webapp.router.add_get("/remote", page)
        webapp.router.add_get("/remote/api/status", status)
        webapp.router.add_post("/remote/api/control/{action}", control)
        webapp.router.add_get("/remote/api/search", search)
        webapp.router.add_post("/remote/api/play", play)
        webapp.router.add_get("/remote/api/theme", theme)

    def slim_status(self) -> dict:
        s = self.app.status()
        p = s["player"]
        return {"version": s["version"],
                "track": _slim(p["track"]) if p.get("track") else None,
                "playing": p["playing"], "paused": p["paused"], "position": p["position"],
                "duration": p["duration"], "volume": p["volume"], "shuffle": p["shuffle"],
                "repeat": p["repeat"], "queueIndex": p["queueIndex"], "queueLength": p["queueLength"],
                "upNext": [_slim(t) for t in p.get("upNext", [])[:40]],
                "context": (p.get("context") or {}).get("title", ""),
                "sleep": s.get("listening", {}).get("sleep"),
                "signedIn": self.app.tidal.signed_in}


def _slim(t: dict) -> dict:
    out = {k: t.get(k) for k in ("id", "title", "artists", "album", "albumId", "artistId", "duration", "art",
                                 "provider", "kind", "explicit")}
    if t.get("radio"):
        out["radio"] = t["radio"]
    return {k: v for k, v in out.items() if v not in (None, "")}
