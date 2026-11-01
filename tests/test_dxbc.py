"""Every shipped .qsb carries DXBC: without it D3D11 compiles the HLSL on the
render thread at first draw, and a heavy style (ridge, prism) froze the window
for 7-11 s, long enough for Windows to call Orpheus hung (orpheusd/dxbc.py)."""
import subprocess
import sys
import unittest
from pathlib import Path

from orpheusd import system

SHADERS = Path(__file__).resolve().parent.parent / "shaders"


@unittest.skipUnless(sys.platform == "win32" and system.qsb_path(), "needs qsb on Windows")
class ShippedShadersHaveDxbc(unittest.TestCase):
    def test_every_package_has_dxbc(self):
        missing = []
        for q in sorted(SHADERS.glob("*.qsb")):
            out = subprocess.run([system.qsb_path(), "-d", str(q)], capture_output=True, text=True,
                                 env=system.qsb_env(), creationflags=0x08000000).stdout
            if "DXBC 50" not in out:
                missing.append(q.name)
        self.assertEqual(missing, [], "run build-shaders.sh (it bakes DXBC on Windows)")


if __name__ == "__main__":
    unittest.main()
