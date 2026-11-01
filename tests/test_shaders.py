"""orpheusd/shaders.py: translation, error mapping, the folder scan, imports and
the routes. No network and no qsb: the compiler is injected."""

import asyncio
import json
import os
import shutil
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

from aiohttp import web
from aiohttp.test_utils import TestClient, TestServer

from orpheusd import shaders as S
from orpheusd.__main__ import guard_middleware

COMMON = S.COMMON.read_text(encoding="utf-8")

SAMPLE = """// a Common tab
float wave(float x) { return sin(x); }

#version 300 es
precision highp float;
uniform float iTime;
uniform vec3 iResolution;
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;
    vec2 m = iMouse.xy / iResolution.xy;
    float s = 0.0;
    for (int i = 0; i < 4; i++) s += iChannelResolution[i].x;
    float f = texture2D(iChannel0, vec2(uv.x, 0.25)).x + gl_FragCoord.x * 0.0;
    fragColor = vec4(vec3(f * wave(iTime) + m.x), 1.0);
}
"""

PLAIN = "void mainImage(out vec4 o, in vec2 p) { o = vec4(p.x / iResolution.x, 0.2, 0.4, 1.0); }\n"


class Fake:
    """A compiler: writes a fake package, or fails like glslang does."""

    def __init__(self):
        self.calls = 0
        self.fail = False

    def __call__(self, glsl: Path, out: Path):
        self.calls += 1
        if self.fail:
            return 1, "Shader baking failed: ERROR: :3: 'foo' : undeclared identifier \nERROR: :3: '' : compilation terminated \n"
        out.write_bytes(b"QSB" + glsl.read_bytes()[-64:])
        return 0, ""


class Cfg:
    def __init__(self, key=""):
        self.key = key

    def text(self, k):
        return self.key if k == "shadertoyKey" else ""


# ---- translate -------------------------------------------------------------------

class TranslateTest(unittest.TestCase):
    def test_shadertoy_sample(self):
        tr = S.translate(SAMPLE, common=COMMON, slug="x")
        g = tr.glsl
        self.assertTrue(g.startswith("#version 440\n"))
        self.assertIn("_orpheusOut", g)
        self.assertNotIn("out vec4 fragColor;", g)
        block = g[g.index("uniform buf {"):]
        self.assertLess(block.index("vec4 mouse;"), block.index("\n};"))
        self.assertEqual(g.count("uniform sampler2D iChannel0;"), 1)
        self.assertIn("layout(binding = 1) uniform sampler2D iChannel0;", g)
        self.assertNotIn("iChannel1;", g)
        self.assertNotIn("gl_FragCoord", g)
        self.assertNotIn("texture2D", g)
        self.assertNotIn("uniform float iTime", g)
        self.assertNotIn("#version 300", g)
        lines = g.split("\n")
        self.assertEqual(lines[tr.header_lines - 1], "#line 1")
        self.assertEqual(lines[tr.header_lines], "// a Common tab")
        self.assertEqual(tr.uses, ["iChannel0", "iMouse"])
        self.assertIn("any(isnan(c))", g)
        self.assertIn("_iTime = time;", g)
        # a stripped line is blanked, not removed: line numbers hold
        self.assertEqual(lines[tr.header_lines + 4], "")
        self.assertEqual(lines[tr.header_lines + 7].strip()[:15], "void mainImage(")

    def test_flow_time(self):
        g = S.translate("//! time: flow\n" + PLAIN, common=COMMON, time_mode="flow").glsl
        self.assertIn("_iTime = flow;", g)

    def test_user_helpers_win(self):
        src = "float hash(vec2 p) { return 0.5; }\n" + PLAIN
        g = S.translate(src, common=COMMON).glsl
        self.assertEqual(g.count("float hash(vec2 p)"), 1)
        self.assertIn("float band(float x)", g)       # untouched helpers stay
        # a mention in a comment neither drops a helper nor turns on a channel
        g = S.translate("// hash(x) iMouse iChannel2\n" + PLAIN, common=COMMON)
        self.assertEqual(g.uses, [])
        self.assertIn("float hash(vec2 p) { return fract", g.glsl)

    def test_dependent_helpers_go_too(self):
        g = S.translate("float bandAt(int i) { return 0.0; }\n" + PLAIN, common=COMMON).glsl
        self.assertNotIn("float band(float x)", g)    # band() calls the dropped bandAt()
        self.assertEqual(g.count("float bandAt("), 1)

    def test_native(self):
        src = "#version 440\n//#common\nvoid main() { fragColor = vec4(band(0.5)); }\n"
        tr = S.translate(src, common=COMMON)
        self.assertIn("float band(float x)", tr.glsl)
        self.assertIn("#line 3", tr.glsl)
        self.assertNotIn("Shadertoy idioms", tr.glsl)
        self.assertEqual(tr.uses, [])
        self.assertEqual(tr.header_lines, 0)

    def test_rejections(self):
        for src, msg in (("void foo() {}", "no mainImage"), ("void main() { }", "not a complete fragment shader"),
                         ("samplerCube c;\n" + PLAIN, "cubemaps"), ("#include \"x\"\n" + PLAIN, "#include"),
                         (PLAIN + "//" + "x" * (S.MAX_SOURCE + 1), "256 KB")):
            with self.assertRaises(S.TranslateError) as e:
                S.translate(src, common=COMMON)
            self.assertIn(msg, str(e.exception))

    def test_common_anchor(self):
        b = COMMON.index("uniform buf {")
        self.assertGreater(COMMON.index("\n};", b), b)
        self.assertIn("layout(location = 0) out vec4 fragColor;", COMMON)


class ErrorsTest(unittest.TestCase):
    def test_forms(self):
        for out in ("ERROR: 0:7: msg", "ERROR: C:\\x\\p.glsl:7: msg", "Shader baking failed: ERROR: :7: msg \r\n"):
            err, errs = S.map_errors(out, 100, 50)
            self.assertEqual(errs, [{"line": 7, "msg": "msg"}], out)
            self.assertEqual(err, "line 7: msg")

    def test_header_fallback_dedupe_cap(self):
        err, errs = S.map_errors("ERROR: 0:130: late\nERROR: 0:130: late", 100, 50)
        self.assertEqual(errs, [{"line": 30, "msg": "late"}])
        out = "\n".join(f"ERROR: 0:{i}: e{i}" for i in range(1, 12))
        self.assertEqual(len(S.map_errors(out, 100, 50)[1]), 6)
        self.assertEqual(S.map_errors("ERROR: :3: '' : compilation terminated", 0, 9)[1], [])
        self.assertEqual(S.map_errors("weird", 0, 9), ("weird", []))


class NamesTest(unittest.TestCase):
    def test_slug(self):
        self.assertEqual(S.slugify("Neon Rain!"), "neon-rain")
        self.assertEqual(S.slugify("***"), "shader")
        self.assertEqual(len(S.slugify("a" * 99)), 40)

    def test_refs(self):
        self.assertEqual(S.parse_shadertoy_ref("https://www.shadertoy.com/view/XsXXDn"), "XsXXDn")
        self.assertEqual(S.parse_shadertoy_ref("shadertoy.com/embed/XsXXDn? "), None)
        self.assertEqual(S.parse_shadertoy_ref("http://shadertoy.com/embed/ab12CD?gui=true"), "ab12CD")
        self.assertEqual(S.parse_shadertoy_ref(" ab12CD "), "ab12CD")
        for junk in ("hello", "ab12CDx", "https://example.com/view/ab12CD", ""):
            self.assertIsNone(S.parse_shadertoy_ref(junk), junk)

    def test_pragmas(self):
        p = S.parse_pragmas("//! name: Neon\n//! scale: 3\n//! time: FLOW\n//! transition: 9\n//! what: x\n")
        self.assertEqual(p, {"name": "Neon", "scale": 1.0, "time": "flow", "transition": 4})
        self.assertEqual(S.parse_pragmas("//! scale: 0.1")["scale"], 0.25)
        self.assertEqual(S.parse_pragmas("\n" * 41 + "//! name: late"), {})


# ---- the folder ------------------------------------------------------------------

class FolderTest(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="orpheus-shaders-"))
        self.fake = Fake()
        self.changes = 0

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def make(self, compiler="fake", **kw):
        def bump():
            self.changes += 1
        return S.UserShaders(self.tmp, on_change=bump, compiler=self.fake if compiler == "fake" else compiler, **kw)

    def write(self, name, text, age=5.0):
        p = self.tmp / name
        p.write_text(text, encoding="utf-8")
        t = time.time() - age
        os.utime(p, (t, t))
        return p

    def builds(self, name):
        return sorted(p.name for p in (self.tmp / ".build").glob(name + "-*.frag.qsb"))

    async def test_lifecycle(self):
        u = self.make()
        await u.scan()
        self.assertTrue((self.tmp / "welcome.frag").exists())     # seeded
        self.assertTrue((self.tmp / "README.txt").exists())
        v0 = u.version
        self.write("a.frag", PLAIN)
        await u.scan()
        a = u.styles["a"]
        self.assertTrue(a.ok, a.error)
        self.assertRegex(a.url, r"/a-[0-9a-f]{12}\.frag\.qsb$")
        self.assertGreater(u.version, v0)
        self.assertGreater(self.changes, 0)
        calls, url1 = self.fake.calls, a.url

        # identical text saved again: same build, no compiler run
        self.write("a.frag", PLAIN, age=3)
        await u.scan()
        self.assertEqual(u.styles["a"].url, url1)
        self.assertEqual(self.fake.calls, calls)

        # an edit: new hash and URL, the previous build kept
        self.write("a.frag", PLAIN.replace("0.2", "0.3"), age=2)
        await u.scan()
        url2 = u.styles["a"].url
        self.assertNotEqual(url2, url1)
        self.assertEqual(len(self.builds("a")), 2)
        first = url1.rsplit("/", 1)[1]
        # a third build prunes the first
        self.write("a.frag", PLAIN.replace("0.2", "0.4"), age=1)
        await u.scan()
        self.assertEqual(len(self.builds("a")), 2)
        self.assertNotIn(first, self.builds("a"))
        url3 = u.styles["a"].url

        # a failing edit keeps the last good build drawing
        self.fake.fail = True
        self.write("a.frag", "\n\nfoo;\n" + PLAIN, age=0.5)
        await u.scan()
        a = u.styles["a"]
        self.assertFalse(a.ok)
        self.assertEqual(a.url, url3)
        self.assertEqual(a.error, "line 3: 'foo' : undeclared identifier")
        self.assertEqual(a.errors, [{"line": 3, "msg": "'foo' : undeclared identifier"}])
        self.assertTrue((self.tmp / ".build" / "a.log").exists())
        calls = self.fake.calls
        await u.scan()                         # a known failure is not retried every second
        self.assertEqual(self.fake.calls, calls)
        self.assertEqual([s["name"] for s in u.describe()["styles"]], ["a", "welcome"])

        # deleting the file removes the style and its builds
        (self.tmp / "a.frag").unlink()
        v = u.version
        await u.scan()
        self.assertNotIn("a", u.styles)
        self.assertEqual(self.builds("a"), [])
        self.assertFalse((self.tmp / ".build" / "a.log").exists())
        self.assertGreater(u.version, v)

    async def test_settle_and_ignored(self):
        u = self.make()
        for n in ("_x.frag", ".hidden.frag", "notes.txt"):
            self.write(n, PLAIN)
        self.write("fresh.frag", PLAIN, age=0)
        await u.scan()
        self.assertEqual(sorted(u.styles), ["welcome"])     # fresh.frag is still settling
        await u.scan(now={"fresh"})
        self.assertIn("fresh", u.styles)

    async def test_same_slug_keeps_first(self):
        u = self.make()
        self.write("My Shader.frag", PLAIN)
        self.write("my-shader.frag", PLAIN.replace("0.2", "0.9"))
        await u.scan()
        self.assertEqual(u.styles["my-shader"].src.name, "My Shader.frag")

    async def test_bad_translation(self):
        u = self.make()
        self.write("b.frag", "void main() {}")
        await u.scan()
        self.assertFalse(u.styles["b"].ok)
        self.assertIn("mainImage", u.styles["b"].error)
        self.assertNotIn("b", [s["name"] for s in u.describe()["styles"] if s["url"]])

    async def test_no_compiler(self):
        u = self.make()
        self.write("a.frag", PLAIN)
        await u.scan()
        self.assertTrue(u.styles["a"].ok)
        with mock.patch.dict(os.environ, {"ORPHEUS_QSB": ""}):
            u2 = self.make(compiler=None)
            self.write("b.frag", PLAIN.replace("0.2", "0.7"))
            await u2.scan()
            d = u2.describe()
            self.assertIsNone(d["compiler"])
            self.assertFalse(u2.status()["compiler"])
            self.assertTrue(u2.styles["a"].ok)                 # built before: still drawing
            self.assertEqual(u2.styles["b"].error, "no shader compiler (qsb)")
            self.assertEqual(u2.styles["b"].url, "")

    async def test_manifest_round_trip(self):
        u = self.make()
        self.write("a.frag", "//! name: Alpha\n//! scale: 0.5\n//! transition: 2\n" + PLAIN)
        await u.scan()
        calls = self.fake.calls
        m = json.loads((self.tmp / ".build" / "manifest.json").read_text())
        self.assertEqual(m["v"], 1)
        u2 = self.make()
        await u2.scan()
        self.assertEqual(self.fake.calls, calls)               # a restart runs zero compiles
        a = u2.styles["a"]
        self.assertEqual((a.label, a.scale, a.transition, a.url), ("Alpha", 0.5, 2, u.styles["a"].url))
        self.assertTrue(a.ok)
        self.assertGreater(u2.version, 0)

    async def test_seeded_once(self):
        u = self.make()
        await u.scan()
        (self.tmp / "welcome.frag").unlink()
        (self.tmp / "README.txt").unlink()
        u2 = self.make()
        await u2.scan()
        self.assertFalse((self.tmp / "welcome.frag").exists())
        self.assertFalse((self.tmp / "README.txt").exists())
        self.assertNotIn("welcome", u2.styles)

    async def test_welcome_translates(self):
        tr = S.translate((S.DATA / "welcome.frag").read_text(encoding="utf-8"), common=COMMON)
        self.assertEqual(tr.uses, ["iChannel0"])
        self.assertEqual(S.parse_pragmas((S.DATA / "welcome.frag").read_text())["name"], "Welcome")

    # ---- imports ----

    async def test_import_text(self):
        u = self.make()
        st = await u.import_text(PLAIN, "Neon Rain")
        self.assertEqual((st.name, st.label, st.origin), ("neon-rain", "Neon Rain", {"kind": "paste"}))
        self.assertTrue(st.ok)
        st2 = await u.import_text("//! name: Neon Rain\n" + PLAIN.replace("0.2", "0.5"))
        self.assertEqual(st2.name, "neon-rain-2")
        st3 = await u.import_text(PLAIN.replace("0.2", "0.6"))
        self.assertEqual(st3.name, "pasted")
        with self.assertRaises(ValueError):
            await u.import_text("hello there")

    async def test_import_shadertoy(self):
        u = self.make(config=Cfg("SECRETKEY"))
        api = {"Shader": {"info": {"id": "ab12CD", "name": "Neon Rain", "username": "iq"},
                          "renderpass": [{"type": "common", "code": "float k() { return 1.0; }"},
                                         {"type": "image", "code": PLAIN, "inputs": [{"channel": 0, "ctype": "music"},
                                                                                       {"channel": 1, "ctype": "texture"}]}]}}
        with mock.patch.object(S.ShadertoyClient, "fetch", mock.AsyncMock(return_value=api)) as f:
            st = await u.import_ref("https://www.shadertoy.com/view/ab12CD")
        f.assert_awaited_once_with("ab12CD", "SECRETKEY")
        text = (self.tmp / "neon-rain.frag").read_text()
        self.assertTrue(text.startswith("//! name: Neon Rain\n//! source: https://www.shadertoy.com/view/ab12CD\n//! author: iq\n"))
        self.assertIn("CC BY-NC-SA", text)
        self.assertIn("iChannel1 was a texture", text)
        self.assertLess(text.index("float k()"), text.index("mainImage"))
        self.assertTrue(st.ok)
        self.assertEqual(st.origin, {"kind": "shadertoy", "id": "ab12CD", "author": "iq",
                                     "url": "https://www.shadertoy.com/view/ab12CD"})

        multi = {"Shader": {"info": {}, "renderpass": [{"type": "buffer", "code": PLAIN}, {"type": "image", "code": PLAIN}]}}
        with mock.patch.object(S.ShadertoyClient, "fetch", mock.AsyncMock(return_value=multi)):
            with self.assertRaises(ValueError) as e:
                await u.import_ref("ab12CD")
        self.assertIn("multipass", str(e.exception))
        with mock.patch.object(S.ShadertoyClient, "fetch", mock.AsyncMock(return_value={"Error": "Shader not found"})):
            with self.assertRaises(ValueError) as e:
                await u.import_ref("ab12CD")
        self.assertIn("Shader not found", str(e.exception))

    async def test_import_needs_key(self):
        u = self.make(config=Cfg(""))
        with self.assertRaises(ValueError) as e:
            await u.import_ref("ab12CD")
        self.assertIn("settings ▸ integrations ▸ shadertoy", str(e.exception))

    async def test_import_file(self):
        u = self.make()
        src = self.tmp.parent / f"drop-{os.getpid()}.frag"
        src.write_text(PLAIN)
        try:
            st = await u.import_ref(src.as_uri())
            self.assertEqual(st.name, src.stem)
            self.assertTrue((self.tmp / f"{src.stem}.frag").exists())
            st = await u.import_ref(str(src))                  # a bare path too
            self.assertEqual(st.name, src.stem + "-2")
        finally:
            src.unlink()
        exe = self.tmp.parent / f"drop-{os.getpid()}.exe"
        exe.write_bytes(b"MZ")
        try:
            with self.assertRaises(ValueError) as e:
                await u.import_ref(exe.as_uri())
            self.assertIn("drop a .frag", str(e.exception))
        finally:
            exe.unlink()
        with self.assertRaises(ValueError):
            await u.import_ref("just some words")


class RoutesTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="orpheus-shaders-"))
        self.u = S.UserShaders(self.tmp, compiler=Fake(), config=Cfg(""))
        app = web.Application(middlewares=[guard_middleware])
        S.add_routes(app, self.u)
        self.client = TestClient(TestServer(app))
        await self.client.start_server()

    async def asyncTearDown(self):
        await self.client.close()
        shutil.rmtree(self.tmp, ignore_errors=True)

    async def test_routes(self):
        r = await self.client.post("/shaders/import", json={"url": "ab12CD"})
        self.assertEqual(r.status, 400)
        self.assertIn("settings ▸ integrations ▸ shadertoy", await r.text())
        r = await self.client.post("/shaders/import", json={})
        self.assertEqual(r.status, 400)
        r = await self.client.post("/shaders/import", json={"source": PLAIN, "name": "Mine"})
        self.assertEqual(r.status, 200)
        st = (await r.json())["style"]
        self.assertEqual((st["name"], st["ok"]), ("mine", True))
        self.assertTrue((self.tmp / "mine.frag").exists())
        r = await self.client.get("/shaders")
        d = await r.json()
        self.assertIn("mine", [s["name"] for s in d["styles"]])
        self.assertEqual(d["dir"], str(self.tmp))
        r = await self.client.post("/shaders/reload", json={})
        self.assertEqual(r.status, 200)

    async def test_key_never_leaves(self):
        self.u.config = Cfg("SUPERSECRET")
        api = {"Shader": {"info": {"name": "k"}, "renderpass": [{"type": "image", "code": PLAIN}]}}
        with mock.patch.object(S.ShadertoyClient, "fetch", mock.AsyncMock(return_value=api)):
            r = await self.client.post("/shaders/import", json={"url": "ab12CD"})
            self.assertEqual(r.status, 200)
            self.assertNotIn("SUPERSECRET", await r.text())
        r = await self.client.get("/shaders")
        self.assertNotIn("SUPERSECRET", await r.text())
        for p in self.tmp.rglob("*"):
            if p.is_file():
                self.assertNotIn(b"SUPERSECRET", p.read_bytes(), p)


if __name__ == "__main__":
    unittest.main()
