#!/usr/bin/env python3
"""32-bit OpenGL thunks reach every build ([gl-wow64-patch]); no Wine runs.

The wine pin's opengl32 wow64 thunks pass a 32-bit program's pointers through
ULongToPtr. On iOS a 32-bit program's memory sits in a window at a high base,
so those bare values point at nothing, and every 32-bit OpenGL game crashed
while OPENGL32.dll attached its first thread (a read of TEB32+0xfdc at an
address like 0x302fdc, then "OPENGL32.dll failed to initialize", c0000142).
patches/wine-opengl-winios.patch converts them, but applying it was a manual
step, so builds from a clean wine tree shipped without it.

Checks:
  A. build/ntdll-unix/build.sh applies the patch before it compiles opengl32,
     with the MADEIRA_WINE_OPENGL_PATCH=0 switch, and package-ipa.sh runs
     this check on the built library.
  B. The patch converts the 32-bit TEB with ios_wow_host_ptr and carries the
     marker string the library check looks for.
  C. With a wine checkout: the patch applies to it, or is already in it.
  --lib PATH: the built libntdll_unix.a contains the patched code.
"""
from pathlib import Path
import subprocess, sys

root = Path(__file__).resolve().parents[2]
patch = root / "patches/wine-opengl-winios.patch"
MARKER = b"[winios-gl] ml1340 32-bit GL "

args = sys.argv[1:]
if args[:1] == ["--lib"]:
    if len(args) != 2:
        sys.exit("usage: check-wine-opengl-patch.py [--lib libntdll_unix.a]")
    lib = Path(args[1])
    data = lib.read_bytes()
    if MARKER not in data:
        sys.exit(f"FAIL: {lib} has no patched opengl32 (no '{MARKER.decode()}'): "
                 "32-bit OpenGL games would crash at start. Rebuild build/ntdll-unix/build.sh "
                 "(it applies patches/wine-opengl-winios.patch), or set MADEIRA_WINE_OPENGL_PATCH=0.")
    print(f"PASS: {lib.name} carries the patched 32-bit opengl32 thunks")
    sys.exit(0)

# A. the build applies it before compiling opengl32
build = (root / "build/ntdll-unix/build.sh").read_text()
apply_at = build.find('git -C "$WINE_SRC" apply "$OPENGL_PATCH"')
compile_at = build.find('compile_unixlib "$WINE_SRC/dlls/opengl32/unix_wgl.c"')
assert apply_at != -1, "build.sh does not apply wine-opengl-winios.patch"
assert compile_at != -1, "build.sh no longer compiles opengl32's unix_wgl.c"
assert apply_at < compile_at, "the patch must be applied before opengl32 compiles"
assert 'apply --reverse --check "$OPENGL_PATCH"' in build, "an already patched tree must be accepted"
assert 'MADEIRA_WINE_OPENGL_PATCH:-1}" != 0' in build, "off switch missing"
assert "exit 1" in build[apply_at:compile_at], "a patch that does not apply must stop the build"
assert 'patches/wine-opengl-winios.patch' in build
pkg = (root / "tools/build/package-ipa.sh").read_text()
assert "check-wine-opengl-patch.py\" --lib" in pkg, "package-ipa.sh must check the built library"
print("PASS: A. build.sh applies the patch before opengl32 compiles; package-ipa.sh checks the library")

# B. the patch is the conversion the crash needs
text = patch.read_text()
assert "+    TEB32 *teb32_ptr = ios_wow_host_ptr( teb32 );" in text, "patch no longer converts the 32-bit TEB"
assert "-    TEB32 *teb32_ptr = ULongToPtr( teb32 );" in text
assert MARKER.decode() in text, "marker string missing from the patch"
print("PASS: B. the patch converts the 32-bit TEB with ios_wow_host_ptr and has the marker")

# C. it fits the wine checkout, if there is one
wine = root / "wine"
if not (wine / "dlls/opengl32/unix_private.h").exists():
    print("SKIP: C. no wine checkout")
    sys.exit(0)
def git_apply(*extra):
    return subprocess.run(["git", "-C", str(wine), "apply", *extra, "--check", str(patch)],
                          capture_output=True, text=True).returncode == 0
if git_apply("--reverse"):
    print("PASS: C. the wine tree already has the patch")
elif git_apply():
    print("PASS: C. the patch applies to the wine tree")
else:
    sys.exit("FAIL: C. patches/wine-opengl-winios.patch neither applies to nor is in the wine tree")
