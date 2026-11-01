"""Bake DXBC into a .qsb so Direct3D 11 never compiles HLSL at runtime (Windows).

`qsb --qt6` without -c stores HLSL source only: fxc ships with the Windows SDK,
not with Qt. QRhi's D3D11 backend then runs D3DCompile on the render thread the
first time a shader draws, and the GUI thread waits on it. For a raymarcher
that is seconds (ridge 10.9 s, prism 7 s, cold): Windows calls the app hung.
Qt's own disk cache only fills on a clean exit, so a killed hang never cached
anything and froze again on the next launch.

This extracts the HLSL, compiles it with the same D3DCompiler_47.dll, and adds
it to the package as "dxbc,50", which QRhi takes in preference to source.

  python -m orpheusd.dxbc <file.qsb | dir> [...]     (qsb from system.qsb_path())

Run as its own process (idle priority, through system.run_quiet) so a long
compile never sits on the daemon's threads.
"""
import ctypes, os, subprocess, sys, tempfile, time
from ctypes import wintypes as w
from pathlib import Path

from . import system

QSB = os.environ.get("QSB") or system.qsb_path() or "qsb"
d3dc = ctypes.WinDLL("D3DCompiler_47.dll")

class Blob(ctypes.Structure):
    pass
class BlobVtbl(ctypes.Structure):
    _fields_ = [("QueryInterface", ctypes.c_void_p), ("AddRef", ctypes.c_void_p),
                ("Release", ctypes.WINFUNCTYPE(w.ULONG, ctypes.c_void_p)),
                ("GetBufferPointer", ctypes.WINFUNCTYPE(ctypes.c_void_p, ctypes.c_void_p)),
                ("GetBufferSize", ctypes.WINFUNCTYPE(ctypes.c_size_t, ctypes.c_void_p))]
Blob._fields_ = [("vtbl", ctypes.POINTER(BlobVtbl))]

def _bytes(p):
    b = ctypes.cast(p, ctypes.POINTER(Blob)).contents
    out = ctypes.string_at(b.vtbl.contents.GetBufferPointer(p), b.vtbl.contents.GetBufferSize(p))
    b.vtbl.contents.Release(p)
    return out

def compile_hlsl(src: bytes, entry=b"main", target=b"ps_5_0"):
    code, err = ctypes.c_void_p(), ctypes.c_void_p()
    hr = d3dc.D3DCompile(src, len(src), None, None, None, entry, target, 0, 0, ctypes.byref(code), ctypes.byref(err))
    msg = _bytes(err).decode("utf-8", "replace") if err.value else ""
    if hr < 0 or not code.value:
        raise RuntimeError(f"D3DCompile failed {hr & 0xffffffff:#x}: {msg}")
    return _bytes(code)

def stage(qsb: Path):
    return b"vs_5_0" if qsb.name.endswith(".vert.qsb") else b"ps_5_0"

def bake(qsb: Path, flags=0x08000000):
    with tempfile.TemporaryDirectory() as td:
        hl, dx = Path(td) / "s.hlsl", Path(td) / "s.dxbc"
        r = subprocess.run([QSB, "-x", "hlsl,50", "-o", str(hl), str(qsb)], capture_output=True, creationflags=flags, env=system.qsb_env())
        if r.returncode or not hl.exists():
            raise RuntimeError("extract: " + (r.stderr or r.stdout).decode("utf-8", "replace"))
        t = time.perf_counter()
        dx.write_bytes(compile_hlsl(hl.read_bytes(), target=stage(qsb)))
        ms = (time.perf_counter() - t) * 1000
        r = subprocess.run([QSB, "-r", f"dxbc,50,{dx}", str(qsb)], capture_output=True, creationflags=flags, env=system.qsb_env())
        if r.returncode:
            raise RuntimeError("replace: " + (r.stderr or r.stdout).decode("utf-8", "replace"))
        return ms

if __name__ == "__main__":
    files = []
    for a in sys.argv[1:]:
        p = Path(a)
        files += sorted(p.glob("*.qsb")) if p.is_dir() else [p]
    bad = 0
    for f in files:
        try:
            print(f"{f.name:28s} {bake(f):8.0f} ms")
        except Exception as e:
            bad += 1
            print(f"{f.name:28s} FAILED {e}")
    sys.exit(1 if bad else 0)
