"""The user's own visualizer styles: Shadertoy-style .frag files in one folder.

Each file in SHADER_DIR is wrapped with Orpheus's uniform block and a small
Shadertoy idiom header (iTime, iResolution, iChannel0 = the audio texture...),
compiled with qsb one at a time at idle priority, and published as a style the
UI calls "@<slug>". The compiled package is named after a hash of what was
compiled, so its URL changes exactly when the picture can: the QML swaps the
shader in place with no transition, and nothing is ever overwritten under a
reader. A broken edit keeps the last good build drawing and says why.

Sources come from a file saved in the folder, a pasted image shader, a .frag
dropped on the stage, or a Shadertoy link fetched through the official API with
the user's own app key. Only the Image and Common passes are supported; a
multipass shader gets a readable refusal, not a half-working style.

The folder is plain text the user owns; the daemon keeps its own bookkeeping
under .build/ (builds, the GLSL qsb saw, the compiler log, a manifest that lets
a restart run zero compiler processes). No album art ever reaches a shader.
"""

from __future__ import annotations

import asyncio
import hashlib
import json
import logging
import os
import re
import shutil
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable
from urllib.parse import unquote, urlsplit

from . import system

log = logging.getLogger("orpheus.shaders")

COMMON = Path(__file__).resolve().parent.parent / "shaders" / "_common.glsl"
DATA = Path(__file__).resolve().parent / "data"
UA = "Orpheus/0.1 (https://github.com/GeneralDussDuss/orpheus)"
API = "https://www.shadertoy.com/api/v1/shaders/{id}"

# Bumped when the wrapper changes in a way that should rebuild every style.
BUILD_V = "1"
MAX_SOURCE = 256 * 1024     # a .frag in the folder (a dozen KB is typical)
MAX_DROP = 1024 * 1024      # a file dropped on the stage
SETTLE = 0.3                # seconds a changed file must sit still: editors save in steps
SCAN_EVERY = 1.0
NO_QSB = "no shader compiler (qsb)"
CHANNELS = ("iChannel0", "iChannel1", "iChannel2", "iChannel3")
DROP_SUFFIXES = (".frag", ".glsl", ".fs", ".txt")

_SLUG = re.compile(r"[^a-z0-9_-]+")
_REF = re.compile(r"https?://(?:www\.)?shadertoy\.com/(?:view|embed)/([A-Za-z0-9]{6})\b")
_BARE_ID = re.compile(r"^[A-Za-z0-9]{6}$")
_PRAGMA = re.compile(r"//!\s*(name|scale|time|transition)\s*:\s*(.+)")
_MAIN_IMAGE = re.compile(r"void\s+mainImage\s*\(\s*out\s+vec4\s+\w+\s*,\s*(?:in\s+)?vec2\s+\w+\s*\)")
_STRIP = re.compile(r"^\s*(?:#\s*(?:version|extension)\b.*|precision\s+\w+\s+\w+\s*;.*|uniform\s+[^;]*;.*)$")
_ERROR = re.compile(r"ERROR:\s*(?:.*?):(\d+):\s*(.+)")
_FUNC = re.compile(r"\b([A-Za-z_]\w*)\s+([A-Za-z_]\w*)\s*\(([^()]*)\)\s*\{")
_NOT_FUNCS = {"if", "for", "while", "switch", "return", "else"}


class TranslateError(ValueError):
    """The source can't become a style; the message is shown to the user as is."""


# ---- names, refs, pragmas ----------------------------------------------------

def slugify(s: str) -> str:
    return _SLUG.sub("-", str(s).lower()).strip("-")[:40] or "shader"


def parse_shadertoy_ref(text: str) -> str | None:
    """A shadertoy.com view/embed URL or a bare 6-character id -> the id."""
    t = str(text or "").strip()
    m = _REF.search(t)
    if m:
        return m.group(1)
    return t if _BARE_ID.match(t) else None


def parse_pragmas(src: str) -> dict:
    """`//! name: …`, `//! scale: 0.6`, `//! time: flow`, `//! transition: 2` in the first 40 lines."""
    out: dict = {}
    for line in src.splitlines()[:40]:
        m = _PRAGMA.search(line)
        if not m:
            continue
        k, v = m.group(1), m.group(2).strip()
        if k == "name":
            out["name"] = v[:60]
        elif k == "scale":
            try:
                out["scale"] = max(0.25, min(1.0, float(v)))
            except ValueError:
                pass
        elif k == "time" and v.lower() in ("clock", "flow"):
            out["time"] = v.lower()
        elif k == "transition":
            try:
                out["transition"] = max(0, min(4, int(float(v))))
            except ValueError:
                pass
    return out


# ---- translation ---------------------------------------------------------------

@dataclass
class Translated:
    glsl: str
    header_lines: int   # lines before the user's first line
    uses: list
    user_lines: int


def _code(text: str) -> str:
    """`text` with its comments blanked (newlines kept): what the compiler sees,
    for deciding what a shader uses and defines. A README line that mentions
    iMouse must not switch the hover tracking on."""
    return re.sub(r"/\*.*?\*/|//[^\n]*", lambda m: re.sub(r"[^\n]", " ", m.group(0)), text, flags=re.S)


def _functions(text: str):
    """Top-level function definitions in `text`: (name, start, end) with end just
    past the closing brace. Good enough for _common.glsl and user code."""
    for m in _FUNC.finditer(text):
        if m.group(1) in _NOT_FUNCS or m.group(2) in _NOT_FUNCS:
            continue
        depth, i = 0, m.end() - 1
        while i < len(text):
            if text[i] == "{":
                depth += 1
            elif text[i] == "}":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        yield m.group(2), m.start(), i + 1


def _common_for(common: str, user: str) -> str:
    """_common.glsl with two edits for a translated shader: the output renamed
    (the user's `out vec4 fragColor` parameter must not fight a global) and
    mouse/frame/dt appended to the block. Then every helper the user defines
    themselves (hash, glow, pal…: Shadertoy code is full of them) is dropped,
    along with any helper that calls a dropped one, so the user's own wins
    instead of failing as a redefinition. Line count is kept by blanking."""
    c = common.replace("layout(location = 0) out vec4 fragColor;", "layout(location = 0) out vec4 _orpheusOut;", 1)
    block = c.index("uniform buf {")
    end = c.index("\n};", block)
    c = c[:end] + "\n    vec4 mouse;\n    float frame;\n    float dt;" + c[end:]
    mine = {name for name, _, _ in _functions(_code(user))}
    funcs = [(n, s, e) for n, s, e in _functions(c) if s > end]
    drop = {n for n, _, _ in funcs if n in mine}
    grew = True
    while grew:
        grew = False
        for n, s, e in funcs:
            if n not in drop and any(re.search(rf"\b{re.escape(d)}\s*\(", c[s:e]) for d in drop):
                drop.add(n)
                grew = True
    for n, s, e in sorted(((n, s, e) for n, s, e in funcs if n in drop), key=lambda f: -f[1]):
        c = c[:s] + "\n" * c[s:e].count("\n") + c[e:]
    return c


def translate(src: str, *, common: str, slug: str = "", time_mode: str = "clock") -> Translated:
    """A user .frag -> GLSL 440 that qsb compiles. Pure: unit-tested."""
    if len(src.encode("utf-8", "replace")) > MAX_SOURCE:
        raise TranslateError("shader source over 256 KB")
    lines = src.splitlines()
    if any(l.strip() == "//#common" for l in lines):
        # Orpheus-native: exactly what build-shaders.sh does with the repo's styles.
        # A #line after the splice keeps the compiler's line numbers the file's own.
        out = "\n".join(f"{common.rstrip()}\n#line {i + 2}" if l.strip() == "//#common" else l
                        for i, l in enumerate(lines)) + "\n"
        uses = ["iChannel1"] if re.search(r"\bsampler2D\s+hist\b", src) else []
        return Translated(out, 0, uses, len(lines))
    if not _MAIN_IMAGE.search(src):
        if re.search(r"\bvoid\s+main\s*\(", src):
            raise TranslateError("paste a Shadertoy image shader (mainImage), not a complete fragment shader")
        raise TranslateError("no mainImage(out vec4, in vec2) found; paste the Image tab of a Shadertoy shader")
    if re.search(r"\btextureCube\s*\(|\bsamplerCube\b", src):
        raise TranslateError("cubemaps aren't supported")
    if re.search(r"^\s*#\s*include\b", src, re.M):
        raise TranslateError("#include isn't supported")

    user = [("" if _STRIP.match(l) else l) for l in lines]
    text = "\n".join(user)
    for a, b in (("texture2DLodEXT", "textureLod"), ("texture2DGradEXT", "textureGrad"),
                 ("textureLod2D", "textureLod"), ("texture2D", "texture")):
        text = re.sub(rf"\b{a}\s*\(", b + "(", text)
    text = re.sub(r"\bgl_FragCoord\b", "_fragCoord", text)

    code = _code(text)
    uses = sorted({"iChannel" + n for n in re.findall(r"\biChannel([0-3])\b", code)}
                  | ({"iMouse"} if re.search(r"\biMouse\b", code) else set()))

    head = ["#version 440", _common_for(common, text).rstrip("\n"),
            "", f"// ---- Shadertoy idioms (orpheusd/shaders.py){' · ' + slug if slug else ''} ----"]
    for ch in CHANNELS:
        if ch in uses:
            head.append(f"layout(binding = {int(ch[-1]) + 1}) uniform sampler2D {ch};")
    # Globals set in main(), not macros over the block: a user's local `res` or
    # `time` then can't capture iResolution/iTime.
    head += ["vec4 _fragCoord;", "float _iTime;", "vec3 _iRes;", "vec4 _iMouse;", "vec3 _chanRes[4];", "float _chanTime[4];",
             "#define iTime _iTime", "#define iTimeDelta dt", "#define iFrame int(frame)",
             "#define iFrameRate (1.0 / max(dt, 0.001))", "#define iResolution _iRes", "#define iMouse _iMouse",
             "#define iDate vec4(0.0)", "#define iSampleRate 44100.0",
             "#define iChannelResolution _chanRes", "#define iChannelTime _chanTime", "#line 1"]
    head_text = "\n".join(head)
    header_lines = head_text.count("\n") + 1
    t = "flow" if time_mode == "flow" else "time"
    foot = f"""
void main() {{
    vec2 fc = vec2(qt_TexCoord0.x, 1.0 - qt_TexCoord0.y) * res;    // Shadertoy's origin is bottom-left
    _fragCoord = vec4(fc, 0.0, 1.0);
    _iTime = {t};
    _iRes = vec3(res, 1.0);
    _iMouse = mouse;
    _chanRes[0] = vec3(512.0, 2.0, 1.0); _chanRes[1] = vec3(32.0, 40.0, 1.0);
    _chanRes[2] = vec3(512.0, 2.0, 1.0); _chanRes[3] = vec3(512.0, 2.0, 1.0);
    _chanTime[0] = time; _chanTime[1] = time; _chanTime[2] = time; _chanTime[3] = time;
    vec4 c = vec4(0.0);
    mainImage(c, fc);
    if (any(isnan(c)) || any(isinf(c))) c = vec4(0.0);   // one NaN would poison the RGBA16F trail buffer for good
    c = clamp(c, 0.0, 16.0);
    _orpheusOut = vec4(c.rgb, 1.0) * qt_Opacity;         // opaque and premultiplied, as VizPost expects
}}
"""
    return Translated(head_text + "\n" + text + "\n" + foot, header_lines, uses, len(user))


def map_errors(output: str, header_lines: int, user_lines: int) -> tuple[str, list]:
    """qsb/glslang output -> ("line 7: msg", [{"line": 7, "msg": "msg"}, …]) in the user's file's lines."""
    errs, seen = [], set()
    for m in _ERROR.finditer(output or ""):
        line, msg = int(m.group(1)), m.group(2).strip()
        if line > user_lines and header_lines:
            line -= header_lines        # a toolchain that ignored #line
        msg = re.sub(r"[A-Za-z]:[\\/][^\s:]*[\\/]|/[^\s:]*/", "", msg)
        if (line, msg) in seen or "compilation terminated" in msg:
            continue
        seen.add((line, msg))
        errs.append({"line": line, "msg": msg})
        if len(errs) == 6:
            break
    if errs:
        return f"line {errs[0]['line']}: {errs[0]['msg']}"[:300], errs
    first = next((l.strip() for l in (output or "").splitlines() if l.strip()), "")
    return (first[:300] or "the compiler failed with no message"), []


# ---- the folder ----------------------------------------------------------------

@dataclass
class Style:
    name: str
    label: str
    src: Path
    mtime_ns: int = 0
    size: int = 0
    hash: str = ""
    built: str = ""
    url: str = ""
    error: str = ""
    errors: list = field(default_factory=list)
    uses: list = field(default_factory=list)
    scale: float = 0.8
    timeMode: str = "clock"
    transition: int = -1
    origin: dict = field(default_factory=lambda: {"kind": "file"})
    ms: int = 0

    @property
    def ok(self) -> bool:
        return bool(self.url) and not self.error

    def public(self) -> dict:
        return {"name": self.name, "label": self.label, "ok": self.ok, "error": self.error, "errors": self.errors,
                "url": self.url, "built": self.built, "uses": self.uses, "scale": self.scale,
                "timeMode": self.timeMode, "transition": self.transition, "origin": self.origin, "ms": self.ms}

    def saved(self) -> dict:
        d = self.public()
        for k in ("name", "label", "ok", "url"):
            d.pop(k)
        return dict(d, hash=self.hash, mtime_ns=self.mtime_ns, size=self.size)


def _origin_from(src: str) -> dict:
    """An import's attribution header, read back from the file itself."""
    m = re.search(r"//!\s*source:\s*(https?://\S*shadertoy\.com/view/([A-Za-z0-9]{6}))", src)
    if not m:
        return {"kind": "paste"} if re.search(r"//!\s*source:\s*paste", src) else {"kind": "file"}
    a = re.search(r"//!\s*author:\s*(.+)", src)
    return {"kind": "shadertoy", "id": m.group(2), "author": a.group(1).strip()[:60] if a else "", "url": m.group(1)}


Compiler = Callable[[Path, Path], "tuple[int, str]"]


class UserShaders:
    """Watches SHADER_DIR, compiles what changed, serves the list.

    `compiler(glsl_path, out_path) -> (rc, output)` is blocking and run in a
    thread; None means qsb, found fresh on every pass. `on_change` is the app's
    _changed (it wakes the /status long poll that carries shaders.version)."""

    def __init__(self, folder: Path | None = None, *, config=None, on_change: Callable[[], None] | None = None,
                 compiler: Compiler | None = None, common: Path | None = None):
        self.dir = Path(folder or system.SHADER_DIR)
        self.build = self.dir / ".build"
        self.config = config
        self.on_change = on_change or (lambda: None)
        self._compiler = compiler
        self._common_path = common or COMMON
        self._common: str | None = None
        self.styles: dict[str, Style] = {}
        self.version = int(time.time())
        self._published: list = []
        self._lock = asyncio.Lock()
        self._compiler_info: dict | None = None
        self._qsb_versions: dict[str, str] = {}
        self._dupes_logged: set[str] = set()
        self._manifest: dict = {}
        self._started = False
        self.client = ShadertoyClient()

    # ---- state ------------------------------------------------------------

    def describe(self) -> dict:
        return {"version": self.version, "dir": str(self.dir), "compiler": self._compiler_info,
                "styles": [self.styles[n].public() for n in sorted(self.styles)]}

    def status(self) -> dict:
        return {"version": self.version, "compiler": self._compiler_info is not None}

    def _publish(self):
        now = [self.styles[n].public() for n in sorted(self.styles)]
        if now != self._published:
            self._published = now
            self.version += 1
            self.on_change()

    def common(self) -> str:
        if self._common is None:
            self._common = self._common_path.read_text(encoding="utf-8")
        return self._common

    async def _refresh_compiler(self):
        if self._compiler is not None:
            self._compiler_info = {"path": "(injected)", "version": "test"}
            return
        q = system.qsb_path()
        if not q:
            self._compiler_info = None
            return
        if q not in self._qsb_versions:
            rc, out = await asyncio.to_thread(system.run_quiet, [q, "--version"], timeout=10)
            v = next((l.strip() for l in out.splitlines() if l.strip()), "") if rc == 0 else ""
            self._qsb_versions[q] = v[:60]
        self._compiler_info = {"path": q, "version": self._qsb_versions[q] or "qsb"}

    def _compile_blocking(self, glsl: Path, out: Path) -> tuple[int, str]:
        if self._compiler is not None:
            return self._compiler(glsl, out)
        q = system.qsb_path()
        if not q:
            return 127, NO_QSB
        return system.run_quiet([q, "--qt6", "-o", str(out), str(glsl)], timeout=30)

    # ---- start ------------------------------------------------------------

    def start(self):
        """Folder, seed files (once, ever: deleting them sticks), manifest."""
        if self._started:
            return
        self._started = True
        self.build.mkdir(parents=True, exist_ok=True)
        marker = self.build / "seeded"
        if not marker.exists():
            for src, name in ((DATA / "welcome.frag", "welcome.frag"), (DATA / "shaders-README.txt", "README.txt")):
                dst = self.dir / name
                if src.is_file() and not dst.exists():
                    try:
                        shutil.copy2(src, dst)      # its old mtime: no settle wait
                    except OSError as e:
                        log.warning("couldn't seed %s: %s", name, e)
            marker.write_text("1\n")
        try:
            m = json.loads((self.build / "manifest.json").read_text(encoding="utf-8"))
            if isinstance(m, dict) and m.get("v") == 1 and isinstance(m.get("styles"), dict):
                self._manifest = m["styles"]
        except (OSError, ValueError):
            self._manifest = {}

    async def run(self):
        """The daemon's task: one scandir a second, compiles only what changed."""
        try:
            self.start()
        except OSError as e:
            log.warning("shaders: can't use %s: %s", self.dir, e)
            return
        while True:
            try:
                await self.scan()
            except Exception as e:     # one bad pass must not end the loop
                log.warning("shaders: scan failed: %s", e)
            await asyncio.sleep(SCAN_EVERY)

    # ---- scan ---------------------------------------------------------------

    def _list(self) -> dict[str, os.DirEntry]:
        found: dict[str, os.DirEntry] = {}
        try:
            entries = sorted(os.scandir(self.dir), key=lambda e: e.name.lower())
        except OSError:
            return found
        for e in entries:
            n = e.name
            if not n.lower().endswith(".frag") or n.startswith((".", "_")):
                continue
            try:
                if not e.is_file() or e.stat().st_size > MAX_SOURCE:
                    continue
            except OSError:
                continue
            slug = slugify(n[:-5])
            if slug in found:
                if n not in self._dupes_logged:
                    self._dupes_logged.add(n)
                    log.warning("shaders: %s and %s are both style @%s; keeping the first", found[slug].name, n, slug)
                continue
            found[slug] = e
        return found

    async def scan(self, *, force: bool = False, now: set | None = None):
        """One pass. `force` recompiles whatever has no build on disk (the reload
        route); `now` skips the settle wait for those names (an import)."""
        if not self._started:
            self.start()
        async with self._lock:
            if force or self._compiler_info is None or not self.styles:
                await self._refresh_compiler()
            found = self._list()
            dirty = False
            for name in [n for n in self.styles if n not in found]:
                self._forget(name)
                dirty = True
            for name, e in found.items():
                try:
                    stt = e.stat()
                except OSError:
                    continue
                st = self.styles.get(name) or self._from_manifest(name, Path(e.path))
                st.src = Path(e.path)
                same = st.mtime_ns == stt.st_mtime_ns and st.size == stt.st_size
                # qsb turned up since (dropped into the tools dir): retry without an edit
                retry = st.error == NO_QSB and self._compiler_info is not None
                if same and not force and not retry and (st.error or self._build_ok(st)):
                    self.styles[name] = st
                    continue        # built, or a known failure waiting for the next edit
                if not same and (not now or name not in now) and time.time() - stt.st_mtime < SETTLE:
                    continue        # still being written: a new file isn't listed until it settles
                self.styles[name] = st
                await self._compile(st, stt)
                dirty = True
            if dirty:
                await self._save()
            self._publish()

    def _build_ok(self, st: Style) -> bool:
        return bool(st.built) and (self.build / f"{st.name}-{st.built}.frag.qsb").is_file()

    def _from_manifest(self, name: str, src: Path) -> Style:
        st = Style(name=name, label=name.replace("-", " ").replace("_", " ").title(), src=src)
        m = self._manifest.get(name)
        if isinstance(m, dict):
            for k in ("hash", "built", "error", "errors", "uses", "scale", "timeMode", "transition", "origin", "ms",
                      "mtime_ns", "size"):
                if k in m:
                    setattr(st, k, m[k])
            if m.get("label"):
                st.label = m["label"]
            if self._build_ok(st):
                st.url = (self.build / f"{name}-{st.built}.frag.qsb").as_uri()
            else:
                st.built, st.mtime_ns = "", 0     # its build is gone: compile again
        return st

    def _forget(self, name: str):
        self.styles.pop(name, None)
        self._manifest.pop(name, None)
        for p in self._builds(name):
            p.unlink(missing_ok=True)
        for ext in (".glsl", ".log"):
            (self.build / (name + ext)).unlink(missing_ok=True)
        log.info("shaders: @%s removed", name)

    def _builds(self, name: str) -> list[Path]:
        pat = re.compile(rf"^{re.escape(name)}-[0-9a-f]{{12}}\.frag\.qsb$")
        try:
            return [self.build / n for n in os.listdir(self.build) if pat.match(n)]
        except OSError:
            return []

    async def _compile(self, st: Style, stt):
        t0 = time.monotonic()
        try:
            src = st.src.read_text(encoding="utf-8", errors="replace")
        except OSError as e:
            st.error, st.errors = f"can't read the file: {e.strerror or e}", []
            return
        st.mtime_ns, st.size = stt.st_mtime_ns, stt.st_size
        p = parse_pragmas(src)
        native = any(l.strip() == "//#common" for l in src.splitlines())
        st.label = p.get("name") or st.name.replace("-", " ").replace("_", " ").title()
        st.scale = p.get("scale", 1.0 if native else 0.8)
        st.timeMode = p.get("time", "clock")
        st.transition = p.get("transition", -1)
        st.origin = _origin_from(src)
        try:
            tr = translate(src, common=self.common(), slug=st.name, time_mode=st.timeMode)
        except TranslateError as e:
            st.error, st.errors, st.hash = str(e), [], ""
            st.ms = int((time.monotonic() - t0) * 1000)
            return
        st.uses = tr.uses
        h = hashlib.sha1((BUILD_V + tr.glsl).encode("utf-8")).hexdigest()[:12]
        st.hash = h
        out = self.build / f"{st.name}-{h}.frag.qsb"
        if out.is_file():
            # Built before (an undo, a restart, a revert): no process at all.
            st.built, st.url, st.error, st.errors = h, out.as_uri(), "", []
            try:
                os.utime(out)
            except OSError:
                pass
            st.ms = int((time.monotonic() - t0) * 1000)
            return
        if self._compiler is None and not system.qsb_path():
            st.error, st.errors = NO_QSB, []
            return
        glsl = self.build / f"{st.name}.glsl"
        tmp = out.with_suffix(".tmp")
        glsl.write_text(tr.glsl, encoding="utf-8", newline="\n")
        rc, output = await asyncio.to_thread(self._compile_blocking, glsl, tmp)
        try:
            (self.build / f"{st.name}.log").write_text(output or "", encoding="utf-8")
        except OSError:
            pass
        st.ms = int((time.monotonic() - t0) * 1000)
        if rc == 0 and tmp.is_file():
            os.replace(tmp, out)
            st.built, st.url, st.error, st.errors = h, out.as_uri(), "", []
            self._prune(st)
            log.info("shaders: @%s built in %d ms", st.name, st.ms)
            return
        tmp.unlink(missing_ok=True)
        if rc == 124:
            st.error, st.errors = "qsb timed out", []
        elif rc == 127 and not output.startswith("ERROR"):
            st.error, st.errors = NO_QSB, []
        else:
            st.error, st.errors = map_errors(output, tr.header_lines, tr.user_lines)
        log.info("shaders: @%s failed: %s", st.name, st.error)

    def _prune(self, st: Style):
        """Keep the newest two builds: the one on screen and the one before it."""
        def age(p: Path):
            try:
                return p.stat().st_mtime_ns
            except OSError:
                return 0
        keep = f"{st.name}-{st.built}.frag.qsb"
        for p in sorted(self._builds(st.name), key=age, reverse=True)[2:]:
            if p.name != keep:
                p.unlink(missing_ok=True)

    async def _save(self):
        self._manifest = {n: dict(s.saved(), label=s.label) for n, s in self.styles.items()}
        data = json.dumps({"v": 1, "seeded": True, "styles": self._manifest}, indent=1).encode("utf-8")
        try:
            await asyncio.to_thread(system.write_atomic, self.build / "manifest.json", data)
        except OSError as e:
            log.debug("shaders: manifest not saved: %s", e)

    # ---- imports ------------------------------------------------------------

    def _free_slug(self, base: str) -> str:
        base = slugify(base)[:36]
        taken = {slugify(p.stem) for p in self.dir.glob("*.frag")} | set(self.styles)
        if base not in taken:
            return base
        n = 2
        while f"{base}-{n}" in taken:
            n += 1
        return f"{base}-{n}"

    async def _write_and_build(self, slug: str, text: str) -> Style:
        self.start()
        path = self.dir / f"{slug}.frag"
        await asyncio.to_thread(system.write_atomic, path, text.encode("utf-8"))
        await self.scan(now={slug})
        st = self.styles.get(slug)
        if st is None:
            raise ValueError("the shader was saved but could not be read back")
        return st

    async def import_text(self, source: str, name: str | None = None) -> Style:
        """Pasted GLSL (an Image tab, or a native //#common shader)."""
        src = source.replace("\r\n", "\n")
        try:
            translate(src, common=self.common())
        except TranslateError as e:
            raise ValueError(str(e))
        label = (name or "").strip() or parse_pragmas(src).get("name") or "pasted"
        slug = self._free_slug(label)
        head = "" if re.search(r"//!\s*name\s*:", src) else f"//! name: {label[:60]}\n"
        return await self._write_and_build(slug, head + "//! source: paste\n" + src.rstrip("\n") + "\n")

    async def import_ref(self, text: str) -> Style:
        """A shadertoy link or id, or a dropped file (file: URL or absolute path)."""
        t = str(text or "").strip()
        sid = parse_shadertoy_ref(t)
        if sid:
            return await self._import_shadertoy(sid)
        path = None
        if t.lower().startswith("file:"):
            u = urlsplit(t)
            p = unquote(u.path)
            if re.match(r"^/[A-Za-z]:", p):
                p = p[1:]
            if u.netloc and u.netloc.lower() != "localhost":
                p = "//" + u.netloc + p         # a UNC share
            path = Path(p)
        elif os.path.isabs(t) and "\n" not in t:
            path = Path(t)
        if path is None:
            raise ValueError("that is neither a shadertoy link nor a shader file")
        try:
            ok = path.is_file() and path.suffix.lower() in DROP_SUFFIXES and path.stat().st_size <= MAX_DROP
        except OSError:
            ok = False
        if not ok:
            raise ValueError("drop a .frag or .glsl file under 1 MB")
        src = (await asyncio.to_thread(path.read_text, encoding="utf-8", errors="replace")).replace("\r\n", "\n")
        if path.resolve().parent == self.dir.resolve() and path.suffix.lower() == ".frag":
            await self.scan(now={slugify(path.stem)})        # already one of ours
            st = self.styles.get(slugify(path.stem))
            if st:
                return st
        try:
            translate(src, common=self.common())
        except TranslateError as e:
            raise ValueError(str(e))
        return await self._write_and_build(self._free_slug(path.stem), src.rstrip("\n") + "\n")

    async def _import_shadertoy(self, sid: str) -> Style:
        key = self.config.text("shadertoyKey") if self.config is not None else ""
        if not key:
            raise ValueError("no Shadertoy app key: add one under settings ▸ integrations ▸ shadertoy, "
                             "or paste the shader's code instead")
        log.info("shaders: fetching shadertoy %s", sid)     # the id only, never the key
        d = await self.client.fetch(sid, key)
        src, info = shadertoy_source(d, sid)
        return await self._write_and_build(self._free_slug(info.get("name") or sid), src)


def shadertoy_source(d: dict, sid: str) -> tuple[str, dict]:
    """The API's JSON -> (the .frag text with its attribution header, info)."""
    if not isinstance(d, dict):
        raise ValueError("shadertoy sent something that isn't a shader")
    if d.get("Error"):
        raise ValueError(f"shadertoy: {str(d['Error'])[:200]}")
    sh = d.get("Shader") or {}
    info = sh.get("info") or {}
    passes = sh.get("renderpass") or []
    kinds = [str(p.get("type", "")).lower() for p in passes]
    if any(k in ("buffer", "cubemap") for k in kinds):
        raise ValueError("multipass shaders (Buffer A-D, cubemaps) aren't supported; only Image + Common with an audio channel")
    image = next((p for p in passes if str(p.get("type", "")).lower() == "image"), None)
    if not image or not image.get("code"):
        raise ValueError("that shader has no Image pass")
    common = next((p.get("code", "") for p in passes if str(p.get("type", "")).lower() == "common"), "")
    notes = []
    for inp in image.get("inputs") or []:
        ct, ch = str(inp.get("ctype", "")).lower(), inp.get("channel", "?")
        if ct in ("cubemap", "volume"):
            raise ValueError(f"iChannel{ch} is a {ct}; only 2D audio and texture channels can be stood in for")
        if ct in ("buffer",):
            raise ValueError("multipass shaders (Buffer A-D, cubemaps) aren't supported; only Image + Common with an audio channel")
        if ct not in ("music", "musicstream", "mic", "none", ""):
            notes.append(f"// note: iChannel{ch} was a {ct}; it reads the audio texture here")
    name = re.sub(r"[\r\n]+", " ", str(info.get("name") or sid)).strip()[:60]
    author = re.sub(r"[\r\n]+", " ", str(info.get("username") or "")).strip()[:60]
    head = [f"//! name: {name}", f"//! source: https://www.shadertoy.com/view/{sid}", f"//! author: {author}",
            "// licence: Shadertoy default CC BY-NC-SA 3.0 unless the page says otherwise"] + notes
    body = (common.rstrip("\n") + "\n\n" if common.strip() else "") + str(image["code"]).replace("\r\n", "\n")
    return "\n".join(head) + "\n\n" + body.rstrip("\n") + "\n", {"name": name, "author": author}


class ShadertoyClient:
    """The official API only (https://www.shadertoy.com/howto#q2): the shader
    must be published as "Public + API". The key rides in the query string and
    nowhere else; it is never logged."""

    async def fetch(self, sid: str, key: str) -> dict:
        import aiohttp
        try:
            timeout = aiohttp.ClientTimeout(total=10)
            async with aiohttp.ClientSession(timeout=timeout, headers={"User-Agent": UA}) as s:
                async with s.get(API.format(id=sid), params={"key": key}) as r:
                    if r.status != 200:
                        raise ValueError(f"shadertoy returned {r.status}: the key is wrong, "
                                         "or the shader is not published as Public + API")
                    return await r.json(content_type=None)
        except ValueError:
            raise
        except (aiohttp.ClientError, asyncio.TimeoutError) as e:
            raise ValueError(f"couldn't reach shadertoy ({type(e).__name__})")


def add_routes(app, shaders: UserShaders):
    """GET /shaders, POST /shaders/import, POST /shaders/reload."""
    from aiohttp import web

    async def body(req):
        try:
            b = await req.json()
            return b if isinstance(b, dict) else {}
        except Exception:
            return {}

    async def get(req):
        return web.json_response(shaders.describe())

    async def do_import(req):
        b = await body(req)
        try:
            if b.get("source"):
                st = await shaders.import_text(str(b["source"]), str(b["name"]) if b.get("name") else None)
            elif b.get("url"):
                st = await shaders.import_ref(str(b["url"]))
            else:
                raise ValueError("send url or source")
        except ValueError as e:
            raise web.HTTPBadRequest(text=str(e))
        return web.json_response({"style": st.public()})

    async def reload(req):
        await shaders.scan(force=True)
        return web.json_response(shaders.describe())

    app.router.add_get("/shaders", get)
    app.router.add_post("/shaders/import", do_import)
    app.router.add_post("/shaders/reload", reload)
