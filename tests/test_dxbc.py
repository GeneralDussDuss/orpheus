"""Every shipped .qsb carries DXBC: without it D3D11 compiles the HLSL on the
render thread at first draw, and a heavy style (ridge, prism) froze the window
for 7-11 s, long enough for Windows to call Orpheus hung (orpheusd/dxbc.py)."""
import os
import subprocess
import sys
import unittest
from pathlib import Path

from orpheusd import system

SHADERS = Path(__file__).resolve().parent.parent / "shaders"


def _qsb():
    """qsb, looked up at run time: other test modules point LOCALAPPDATA at a
    sandbox while they run, which hides the documented drop-in spot."""
    home = Path.home() / "AppData" / "Local" / "Orpheus" / "tools" / "qsb" / "qsb.exe"
    return system.qsb_path() or (str(home) if home.is_file() else None)


def _need_qsb(t):
    if sys.platform != "win32" or not _qsb():
        t.skipTest("needs qsb and Direct3D 11 on Windows")
    os.environ.setdefault("QSB", _qsb())


class ShippedShadersHaveDxbc(unittest.TestCase):
    def test_every_package_has_dxbc(self):
        _need_qsb(self)
        missing = []
        for q in sorted(SHADERS.glob("*.qsb")):
            out = subprocess.run([_qsb(), "-d", str(q)], capture_output=True, text=True,
                                 env=system.qsb_env(), creationflags=0x08000000).stdout
            if "DXBC 50" not in out:
                missing.append(q.name)
        self.assertEqual(missing, [], "run build-shaders.sh (it bakes DXBC on Windows)")


if __name__ == "__main__":
    unittest.main()


_PIX = r'''
import sys
from PySide6.QtCore import QSize, QUrl, QByteArray
from PySide6.QtGui import (QGuiApplication, QRhiTexture, QRhiRenderBuffer, QRhiColorAttachment,
                           QRhiTextureRenderTargetDescription, QRhiReadbackResult, QRhiReadbackDescription, QImage)
from PySide6.QtQml import QQmlEngine, QQmlComponent
from PySide6.QtQuick import QQuickRenderControl, QQuickWindow, QQuickRenderTarget, QSGRendererInterface
app = QGuiApplication(sys.argv[:1] + ["-platform", "offscreen"])
# A render control on Direct3D 11 with no native window: the offscreen
# platform alone would fall back to the software renderer, which runs no shaders.
QQuickWindow.setSceneGraphBackend("rhi")
QQuickWindow.setGraphicsApi(QSGRendererInterface.GraphicsApi.Direct3D11)
rc = QQuickRenderControl(); win = QQuickWindow(rc); win.resize(400, 200); win.contentItem().setSize(win.size())
assert rc.initialize()
rhi = rc.rhi(); sz = QSize(400, 200)
tex = rhi.newTexture(QRhiTexture.Format.RGBA8, sz, 1, QRhiTexture.Flag.RenderTarget | QRhiTexture.Flag.UsedAsTransferSource); tex.create()
ds = rhi.newRenderBuffer(QRhiRenderBuffer.Type.DepthStencil, sz, 1); ds.create()
desc = QRhiTextureRenderTargetDescription(QRhiColorAttachment(tex)); desc.setDepthStencilBuffer(ds)
rt = rhi.newTextureRenderTarget(desc); rp = rt.newCompatibleRenderPassDescriptor(); rt.setRenderPassDescriptor(rp); rt.create()
win.setRenderTarget(QQuickRenderTarget.fromRhiRenderTarget(rt))
s = """import QtQuick
Item { width: 400; height: 200
  Text { text: "glyph atlas ABCDEFGHIJ 0123456789"; font.pixelSize: 30; color: "white" }
  Rectangle { id: g; width: 64; height: 64; color: "#00ff00"; layer.enabled: true; visible: false }
  ShaderEffect { x: 100; y: 60; width: 200; height: 120; property var src: g; fragmentShader: "%s" } }""" % QUrl.fromLocalFile(sys.argv[1]).toString()
e = QQmlEngine(); c = QQmlComponent(e); c.setData(QByteArray(s.encode()), QUrl("file:///x.qml"))
root = c.create(); root.setParentItem(win.contentItem())
for i in range(2):
    rc.polishItems(); rc.beginFrame(); rc.sync(); rc.render()
    rb = QRhiReadbackResult(); batch = rhi.nextResourceUpdateBatch()
    batch.readBackTexture(QRhiReadbackDescription(tex), rb); rc.commandBuffer().resourceUpdate(batch)
    rc.endFrame()
img = QImage(bytes(rb.data), 400, 200, QImage.Format.Format_RGBA8888_Premultiplied)
y = 120 if not rhi.isYUpInFramebuffer() else 200 - 1 - 120
print(img.pixelColor(200, y).name())
'''

_FRAG = """#version 440
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform buf { mat4 qt_Matrix; float qt_Opacity; };
layout(binding = 1) uniform sampler2D src;
void main() { fragColor = texture(src, qt_TexCoord0) * qt_Opacity; }
"""


class BakedShaderSamplesItsOwnTexture(unittest.TestCase):
    """A baked package must read binding 1 from binding 1. The first bake kept
    qsb's packed registers (binding 1 = t0) with no binding map for the DXBC
    entry, so every style sampled Qt's glyph atlas: red text over the picture."""

    def test_binding_one_reads_the_green_texture(self):
        _need_qsb(self)
        import os
        import tempfile
        with tempfile.TemporaryDirectory() as td:
            frag, qsb, py = (Path(td) / n for n in ("t.frag", "t.frag.qsb", "pix.py"))
            frag.write_text(_FRAG)
            py.write_text(_PIX)
            env = system.qsb_env()
            subprocess.run([_qsb(), "--qt6", "-o", str(qsb), str(frag)], check=True, env=env,
                           capture_output=True, creationflags=0x08000000)
            from orpheusd import dxbc
            dxbc.bake(qsb)
            run = dict(os.environ, QT_DISABLE_SHADER_DISK_CACHE="1", QSG_RHI_DISABLE_DISK_CACHE="1")
            out = subprocess.run([sys.executable, str(py), str(qsb)], capture_output=True, text=True, env=run,
                                 timeout=60, creationflags=0x40 | 0x08000000).stdout.strip().splitlines()
            self.assertEqual(out[-1] if out else "", "#00ff00")
