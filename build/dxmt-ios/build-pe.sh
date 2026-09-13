#!/bin/bash
# Build the four DXMT Windows DLLs for both architectures Wine loads them in:
# aarch64-windows (native ARM64) and arm64ec-windows (ARM64EC, the hybrid set an
# x64 guest session uses). Both are needed. WineProcessBridge.m selects
# arm64ec-windows when the target exe is x64 or was launched by full Win32 path
# -- which is every real game -- and aarch64-windows otherwise, so shipping only
# one silently freezes DXMT at whatever revision that directory was last built.
set -euo pipefail

BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$BUILD_DIR/../.." && pwd)"
DXMT_ROOT="$REPO_ROOT/research/dxmt"
WINE_BUILD="$REPO_ROOT/wine/build-macos"
WINE_BUILD_ARM64EC="$REPO_ROOT/wine/build-macos-arm64ec"
MINGW="$REPO_ROOT/toolchains/llvm-mingw-20260421-ucrt-macos-universal"
PE_BUILD="$BUILD_DIR/pe"
PE_BUILD_ARM64EC="$BUILD_DIR/pe-arm64ec"
JOBS="${JOBS:-3}"

for tool in meson ninja xcrun python3; do
    command -v "$tool" >/dev/null || { echo "Missing build tool: $tool" >&2; exit 1; }
done
for prefix in aarch64 arm64ec; do
    test -x "$MINGW/bin/$prefix-w64-mingw32-clang" || {
        echo "ERROR: llvm-mingw lacks the $prefix target ($prefix-w64-mingw32-clang)." >&2
        exit 1
    }
done
test -x "$WINE_BUILD/tools/winebuild/winebuild"
test -x "$WINE_BUILD_ARM64EC/tools/winebuild/winebuild"
test -s "$DXMT_ROOT/include/native/directx/d3d11.h"
# Reject old setup-only dummy archives before Meson can accidentally accept them.
# Each architecture's imports come from its own Wine tree: one tree cannot hold
# both, because a tree with both enabled makes Wine emit a single ARM64X
# libwinecrt0.a under aarch64-windows/ and no arm64ec-windows/ archive at all.
for arch in aarch64-windows arm64ec-windows; do
    if [[ "$arch" == arm64ec-windows ]]; then tree="$WINE_BUILD_ARM64EC"; else tree="$WINE_BUILD"; fi
    for archive in "$tree/libs/winecrt0/$arch/libwinecrt0.a" \
                   "$tree/dlls/ntdll/$arch/libntdll.a" \
                   "$tree/dlls/dbghelp/$arch/libdbghelp.a"; do
        test -s "$archive" || { echo "Missing $archive; run scripts/prepare-wine-ios.sh --dxmt-pe" >&2; exit 1; }
        members=$("$MINGW/bin/llvm-ar" t "$archive")
        [[ -n "$members" ]] || { echo "Empty Wine import archive: $archive" >&2; exit 1; }
    done
done

export SDKROOT
# The native compiler below is invoked by absolute path (no default sysroot),
# so SDKROOT alone is not enough to find system headers — the Wine host-tools
# build failed exactly this way. Resolve once, verify up front, and pass
# -isysroot explicitly in the Meson native file (harmless if redundant).
MACOS_SDK="$(xcrun --sdk macosx --show-sdk-path)"
if [[ -z "$MACOS_SDK" || ! -d "$MACOS_SDK" ]]; then
    echo "ERROR: macOS SDK not found (xcrun returned '${MACOS_SDK:-<empty>}')." >&2
    exit 1
fi
if [[ ! -f "$MACOS_SDK/usr/include/stdio.h" ]]; then
    echo "ERROR: macOS SDK has no usr/include/stdio.h: $MACOS_SDK" >&2
    exit 1
fi
echo "macOS SDK: $MACOS_SDK"
SDKROOT="$MACOS_SDK"
export PATH="$MINGW/bin:$PATH"
APPLE_CLANG=$(xcrun --find clang)
APPLE_CLANGXX=$(xcrun --find clang++)

# Explicit binary paths avoid source-tree symlinks and accidental selection
# of llvm-mingw's clang as the native macOS compiler.
write_cross_file() {
    local ini="$1" prefix="$2"
    python3 - "$BUILD_DIR" "$MINGW" "$APPLE_CLANG" "$APPLE_CLANGXX" "$MACOS_SDK" "$ini" "$prefix" <<'PY'
import sys
from pathlib import Path

build, mingw = map(Path, sys.argv[1:3])
sdk = sys.argv[5]
ini = build / sys.argv[6]
prefix = sys.argv[7]
def quote(value):
    return "'" + str(value).replace('\\', '\\\\').replace("'", "\\'") + "'"

cross = ['[binaries]']
for key, binary in [('c', 'clang'), ('cpp', 'clang++'), ('ar', 'ar'),
                    ('strip', 'strip'), ('windres', 'windres')]:
    cross.append(f'{key} = {quote(mingw / "bin" / (prefix + "-w64-mingw32-" + binary))}')
# arm64ec reports cpu_family 'aarch64' as well: llvm-mingw's arm64ec target is
# an x86_64-callable hybrid PE, not a separate Meson family, and DXMT detects it
# by compiling a __arm64ec__ probe rather than by reading cpu_family.
cross += [f"xcrun = ['/bin/bash', {quote(build / 'xcrun-ios-shaders.sh')}]",
          '', '[properties]', 'needs_exe_wrapper = true', '', '[host_machine]',
          "system = 'windows'", "cpu_family = 'aarch64'", "cpu = 'aarch64'", "endian = 'little'"]
ini.write_text('\n'.join(cross) + '\n')
sysroot = ['-isysroot', sdk]
(build / 'macos-native.ini').write_text(
    f'[binaries]\nc = {quote(sys.argv[3])}\ncpp = {quote(sys.argv[4])}\n'
    f'\n[built-in options]\n'
    f'c_args = {sysroot}\n'
    f'cpp_args = {sysroot}\n'
    f'c_link_args = {sysroot}\n'
    f'cpp_link_args = {sysroot}\n')
PY
}

# macOS still ships Bash 3.2, where expanding an empty array with `set -u`
# aborts with "unbound variable". Spell out the two Meson invocations so the
# first clean build works as well as a reconfiguration of an existing tree.
build_arch() {
    local label="$1" cross="$2" machine="$3" dest="$4" build_root="$5" wine_build="$6"
    if [[ -f "$build_root/meson-private/coredata.dat" ]]; then
        meson setup --reconfigure --cross-file "$BUILD_DIR/$cross" \
            --native-file "$BUILD_DIR/macos-native.ini" --buildtype release \
            "-Dwine_build_path=$wine_build" "$build_root" "$DXMT_ROOT"
    else
        meson setup --cross-file "$BUILD_DIR/$cross" \
            --native-file "$BUILD_DIR/macos-native.ini" --buildtype release \
            "-Dwine_build_path=$wine_build" "$build_root" "$DXMT_ROOT"
    fi
    meson compile -C "$build_root" -j "$JOBS"

    # The machine word is the whole reason for building twice: a mis-wired cross
    # file still produces a valid PE, just one Wine would load in the session it
    # does not belong to, and the failure surfaces much later as a loader error.
    python3 - "$REPO_ROOT/tools/validate-ios-bundle.py" "$build_root" "$machine" "$label" <<'PY'
import runpy
import sys
from pathlib import Path

validate = runpy.run_path(sys.argv[1])['pe']
build = Path(sys.argv[2])
machine = int(sys.argv[3], 16)
label = sys.argv[4]
for directory, name in [('d3d11', 'd3d11'), ('dxgi', 'dxgi'),
                        ('winemetal', 'winemetal'), ('d3d10', 'd3d10core')]:
    path = build / 'src' / directory / f'{name}.dll'
    validate(path.read_bytes(), machine)
    print(f'Validated {label} PE DLL ({machine:#06x}): {path}')
PY

    mkdir -p "$dest"
    cp "$build_root/src/d3d11/d3d11.dll" "$build_root/src/dxgi/dxgi.dll" \
        "$build_root/src/winemetal/winemetal.dll" "$build_root/src/d3d10/d3d10core.dll" \
        "$dest/"
    echo "Installed $label DLLs into $dest"
}

write_cross_file aarch64-windows.ini aarch64
write_cross_file arm64ec-windows.ini arm64ec

build_arch aarch64 aarch64-windows.ini 0xAA64 \
    "$REPO_ROOT/app/Madeira/aarch64-windows" "$PE_BUILD" "$WINE_BUILD"
build_arch arm64ec arm64ec-windows.ini 0x8664 \
    "$REPO_ROOT/app/Madeira/arm64ec-windows" "$PE_BUILD_ARM64EC" "$WINE_BUILD_ARM64EC"
