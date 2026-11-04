#!/usr/bin/env bash
# Applies Madeira's patches to the wine submodule: patches/wine-*.patch.
#
# patches/wine-opengl-winios.patch carries opengl32's 32-bit (WoW64) support on
# iOS: the regenerated wow64 thunks convert every embedded guest pointer through
# the process's 4 GB window, get_teb64() included, plus the winios OpenGL ES
# contexts. docs/BUILDING.md asked for it to be applied by hand before building;
# a build that skipped it (every CI build) left 32-bit programs that load
# opengl32.dll dying in its thread attach ("opengl32.dll failed to initialize",
# c0000142) -- also programs that only probe DirectX through dxdiagn/ddraw ->
# wined3d -> opengl32, which then report that DirectX 9.0c is missing.
#
# Idempotent: a patch that is already applied is skipped, one that applies is
# applied, and one that does neither stops the build.
set -euo pipefail
ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
WINE="$ROOT/wine"
[[ -f "$WINE/configure" ]] || { echo "apply-wine-patches: wine submodule is missing" >&2; exit 1; }

shopt -s nullglob
for p in "$ROOT"/patches/wine-*.patch; do
  name=$(basename "$p")
  if git -C "$WINE" apply --reverse --check "$p" >/dev/null 2>&1; then
    echo "wine patch $name: already applied"
  elif git -C "$WINE" apply --check "$p" >/dev/null 2>&1; then
    git -C "$WINE" apply "$p"
    echo "wine patch $name: applied"
  else
    echo "ERROR: wine patch $name neither applies nor is already applied:" >&2
    git -C "$WINE" apply --check "$p" >&2 || true
    exit 1
  fi
done
