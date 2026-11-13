#!/bin/bash
# Compile Orpheus's GLSL sources into the .qsb packages Qt Quick loads.
# Each shader's "//#common" line is replaced with shaders/_common.glsl first.
set -euo pipefail

qsb=${QSB:-$(command -v qsb || echo /usr/lib/qt6/bin/qsb)}
cd "$(dirname "$0")/shaders"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

for src in *.frag; do
  sed -e '/\/\/#common/{r _common.glsl' -e 'd}' "$src" >"$tmp/$src"
  "$qsb" --glsl "300es,330" --hlsl 50 --msl 12 -o "$src.qsb" "$tmp/$src"
  # Windows: bake DXBC in, or D3D11 compiles the HLSL at first draw (orpheusd/dxbc.py)
  case "${OSTYPE:-}" in msys*|cygwin*) QSB="$qsb" PYTHONPATH=.. "${PYTHON:-../.venv/Scripts/python}" -m orpheusd.dxbc "$src.qsb" >/dev/null ;; esac
  echo "built shaders/$src.qsb"
done
