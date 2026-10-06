#!/bin/bash
# Build Mesa's Windows x64 OpenGL driver on D3D12 (opengl32.dll and
# libgallium_wgl.dll) from pinned sources, and fetch Microsoft's DXIL
# validator (dxil.dll), into app/Madeira/x86_64-opengl/.
#
# Desktop OpenGL then runs as OpenGL -> D3D12 (Mesa) -> madeira_d3d12 -> Metal.
# WineProcessBridge.m links these files over Wine's opengl32 stub for x64
# sessions; see "OpenGL" in docs/BUILDING.md.
#
# Every input is checked against a pinned SHA-256 or git commit, and Meson
# runs with --wrap-mode=nodownload. Links use --no-insert-timestamp: two clean
# builds give the same bytes. Needs bison 3 (Homebrew), ninja, git, python3,
# and uv or python3 -m venv for Meson and Mako.
set -euo pipefail

BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$BUILD_DIR/../.." && pwd)"
MINGW="${MADEIRA_MINGW:-$REPO_ROOT/toolchains/llvm-mingw-20260421-ucrt-macos-universal}"
CACHE="$REPO_ROOT/toolchains/mesa-d3d12"
WORK="$BUILD_DIR/work"
OUT="$REPO_ROOT/app/Madeira/x86_64-opengl"

MESA_VERSION=26.2.4
MESA_URL="https://archive.mesa3d.org/mesa-$MESA_VERSION.tar.xz"
MESA_SHA256=bce5f7fbebb934373b86c999a064d52fb5065878dc57f287f95346648ec832e9
DXC_URL="https://github.com/microsoft/DirectXShaderCompiler/releases/download/v1.9.2609/dxc_2026_09_29.zip"
DXC_SHA256=ad31b1fc8443175d204f77a611fdb3ef2ec42759bdc2f1167368de24a4a7e7f1
DXIL_SHA256=64be2368211d257a038a7d4ea6bb3e24c878eb8d588c7b8414fccf759b69c2ac
DXHEADERS_URL="https://github.com/microsoft/DirectX-Headers.git"
DXHEADERS_COMMIT=9e393d6d8a3b30dcc6f2806ef604ec16a27b0d7e   # v1.619.1
ZLIB_URL="https://github.com/mesonbuild/wrapdb/releases/download/zlib_1.3.1-1/zlib-1.3.1.tar.gz"
ZLIB_SHA256=9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23
ZLIB_PATCH_URL="https://wrapdb.mesonbuild.com/v2/zlib_1.3.1-1/get_patch"
ZLIB_PATCH_SHA256=e79b98eb24a75392009cec6f99ca5cdca9881ff20bfa174e8b8926d5c7a47095
PATCHES=(optional-shared-fence.patch optional-composition.patch)
PY_TOOLS=(meson==1.9.1 mako==1.3.10 pyyaml==6.0.3 packaging==25.0)

die() { echo "build.sh: $*" >&2; exit 1; }

# fetch URL FILE SHA256: download once into the cache, then require the hash.
fetch() {
    local url=$1 file=$2 want=$3 got
    if [ ! -f "$file" ]; then
        echo "Downloading $url"
        curl -fL --retry 3 -o "$file.part" "$url"
        mv "$file.part" "$file"
    fi
    got=$(shasum -a 256 "$file" | cut -d' ' -f1)
    [ "$got" = "$want" ] || die "$file: SHA-256 $got, expected $want"
}

for tool in curl git ninja patch python3 shasum tar; do
    command -v "$tool" >/dev/null || die "missing tool: $tool"
done
# macOS /usr/bin/bison is 2.3; Mesa's GLSL preprocessor grammar needs bison 3.
BISON_DIR="${BISON_DIR:-/opt/homebrew/opt/bison/bin}"
case "$("$BISON_DIR/bison" --version 2>/dev/null | head -1)" in
    *" 3."*) ;;
    *) die "bison 3 not found in $BISON_DIR (brew install bison, or set BISON_DIR)" ;;
esac
[ -x "$MINGW/bin/x86_64-w64-mingw32-clang" ] || die "llvm-mingw not found at $MINGW (see docs/BUILDING.md)"

mkdir -p "$CACHE"
fetch "$MESA_URL" "$CACHE/mesa-$MESA_VERSION.tar.xz" "$MESA_SHA256"
fetch "$DXC_URL" "$CACHE/dxc_2026_09_29.zip" "$DXC_SHA256"
fetch "$ZLIB_URL" "$CACHE/zlib-1.3.1.tar.gz" "$ZLIB_SHA256"
fetch "$ZLIB_PATCH_URL" "$CACHE/zlib_1.3.1-1_patch.zip" "$ZLIB_PATCH_SHA256"

echo "=== Mesa $MESA_VERSION source ==="
rm -rf "$WORK"
mkdir -p "$WORK"
tar -xJf "$CACHE/mesa-$MESA_VERSION.tar.xz" -C "$WORK"
SRC="$WORK/mesa-$MESA_VERSION"
for p in "${PATCHES[@]}"; do
    patch -d "$SRC" -p1 --forward --batch < "$BUILD_DIR/patches/$p" || die "patch $p does not apply"
done
# Put the pinned subprojects where Meson looks, so it never downloads.
mkdir -p "$SRC/subprojects/packagecache"
cp "$CACHE/zlib-1.3.1.tar.gz" "$CACHE/zlib_1.3.1-1_patch.zip" "$SRC/subprojects/packagecache/"
DXH="$SRC/subprojects/DirectX-Headers-1.0"
git init -q "$DXH"
git -C "$DXH" fetch -q --depth 1 "$DXHEADERS_URL" "$DXHEADERS_COMMIT"
git -C "$DXH" checkout -q FETCH_HEAD
[ "$(git -C "$DXH" rev-parse HEAD)" = "$DXHEADERS_COMMIT" ] || die "DirectX-Headers commit mismatch"

# Meson records the Python path in build.ninja, so the tools get one fixed venv.
if command -v uv >/dev/null; then
    uv venv -q "$WORK/venv"
    uv pip install -q --python "$WORK/venv/bin/python" "${PY_TOOLS[@]}"
else
    python3 -m venv "$WORK/venv"
    "$WORK/venv/bin/pip" install -q "${PY_TOOLS[@]}"
fi
export PATH="$WORK/venv/bin:$BISON_DIR:$PATH"

CROSS="$WORK/mingw-x64.ini"
cat > "$CROSS" <<EOF
[binaries]
c = '$MINGW/bin/x86_64-w64-mingw32-clang'
cpp = '$MINGW/bin/x86_64-w64-mingw32-clang++'
ar = '$MINGW/bin/llvm-ar'
strip = '$MINGW/bin/llvm-strip'
windres = '$MINGW/bin/x86_64-w64-mingw32-windres'
[host_machine]
system = 'windows'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
[properties]
needs_exe_wrapper = true
[built-in options]
c_args = ['-D__USE_MINGW_ANSI_STDIO=1', '-ffile-prefix-map=$WORK=.']
cpp_args = ['-D__USE_MINGW_ANSI_STDIO=1', '-ffile-prefix-map=$WORK=.']
c_link_args = ['-static-libgcc', '-Wl,--no-insert-timestamp']
cpp_link_args = ['-static-libgcc', '-static-libstdc++', '-Wl,--no-insert-timestamp']
EOF

echo "=== opengl32.dll, libgallium_wgl.dll (x86_64) ==="
meson setup "$WORK/build" "$SRC" --cross-file "$CROSS" \
    --wrap-mode=nodownload --buildtype=release --default-library=static \
    -Dplatforms=windows -Dgallium-drivers=d3d12 -Dvulkan-drivers= \
    -Dllvm=disabled -Degl=disabled -Dgles1=disabled -Dgles2=disabled \
    -Dgallium-d3d12-video=disabled -Dvideo-codecs= -Dbuild-tests=false
ninja -C "$WORK/build"

mkdir -p "$OUT"
cp "$WORK/build/src/gallium/targets/libgl-gdi/opengl32.dll" "$OUT/"
cp "$WORK/build/src/gallium/targets/wgl/libgallium_wgl.dll" "$OUT/"

echo "=== dxil.dll (Microsoft DXC v1.9.2609, x64) ==="
# The archive stores Windows paths with backslashes.
python3 - "$CACHE/dxc_2026_09_29.zip" "$OUT" <<'PY'
import os, sys, zipfile
src, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(src) as z:
    for name, dest in (("bin\\x64\\dxil.dll", "dxil.dll"), ("LICENSE-MS.txt", "LICENSE-dxil.txt")):
        with open(os.path.join(out, dest), "wb") as f:
            f.write(z.read(name))
PY
got=$(shasum -a 256 "$OUT/dxil.dll" | cut -d' ' -f1)
[ "$got" = "$DXIL_SHA256" ] || die "dxil.dll: SHA-256 $got, expected $DXIL_SHA256"

(cd "$OUT" && shasum -a 256 opengl32.dll libgallium_wgl.dll dxil.dll)
