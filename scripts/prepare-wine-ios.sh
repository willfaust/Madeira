#!/bin/bash
# Shared, real Wine inputs for the iOS native libraries and optional DXMT PE build.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WINE_SRC="$REPO_ROOT/wine"
WINE_BUILD="$WINE_SRC/build-macos"
WINE_BUILD_ARM64EC="$WINE_SRC/build-macos-arm64ec"
MINGW_VERSION=20260421
MINGW_DIR="$REPO_ROOT/toolchains/llvm-mingw-$MINGW_VERSION-ucrt-macos-universal"
DXMT_PE=0
case "${1:-}" in
    "") ;;
    --dxmt-pe) DXMT_PE=1 ;;
    *) echo "Usage: $0 [--dxmt-pe]" >&2; exit 2 ;;
esac
[[ $# -le 1 ]] || { echo "Usage: $0 [--dxmt-pe]" >&2; exit 2; }

if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
    echo "ERROR: Wine iOS preparation requires an Apple Silicon Mac with Xcode." >&2
    exit 1
fi
[[ -f "$WINE_SRC/configure" ]] || { echo "ERROR: initialize the wine submodule first." >&2; exit 1; }
JOBS="${JOBS:-${BUILD_JOBS:-}}"
if [[ -z "$JOBS" ]]; then
    JOBS="$(sysctl -n hw.ncpu)"
fi
xcrun --sdk iphoneos --show-sdk-version

if [[ ! -x "$MINGW_DIR/bin/aarch64-w64-mingw32-clang" ]]; then
    mkdir -p "$REPO_ROOT/toolchains"
    download="$(mktemp -d "${TMPDIR:-/tmp}/wine-mingw.XXXXXX")"
    trap 'rm -rf "$download"' EXIT
    curl --fail --silent --show-error --location --retry 3 \
        --connect-timeout 30 --max-time 600 --proto '=https' --proto-redir '=https' \
        "https://github.com/mstorsjo/llvm-mingw/releases/download/$MINGW_VERSION/llvm-mingw-$MINGW_VERSION-ucrt-macos-universal.tar.xz" \
        -o "$download/llvm-mingw.tar.xz"
    tar -xJf "$download/llvm-mingw.tar.xz" -C "$REPO_ROOT/toolchains"
fi
export PATH="$MINGW_DIR/bin:$PATH"
# Both targets are required, not just aarch64: DXMT ships DLLs for the native
# ARM64 session and for the ARM64EC session that x64 games actually run in.
# windres and strip are listed because build-pe.sh names them in each cross
# file; a missing one there fails the Meson setup, long after this check.
for prefix in aarch64-w64-mingw32 arm64ec-w64-mingw32; do
    for tool in clang clang++ ar strip windres; do
        [[ -x "$MINGW_DIR/bin/$prefix-$tool" ]] || {
            echo "ERROR: incomplete llvm-mingw: $prefix-$tool missing." >&2
            exit 1
        }
    done
done
for tool in llvm-dlltool llvm-ar lld; do
    [[ -x "$MINGW_DIR/bin/$tool" ]] || { echo "ERROR: incomplete llvm-mingw: $tool missing." >&2; exit 1; }
done
aarch64-w64-mingw32-clang --version
arm64ec-w64-mingw32-clang --version

# ARM64EC defines __x86_64__ (it is an x86_64-callable ARM64 hybrid), so every
# winnt.h guard that keys on __x86_64__ alone selects an x86 inline asm path in
# what is really ARM64 code: winecrt0 then fails with "invalid input constraint
# 'c'" on 'int $0x29', and 'lock; xchgl' assembles as something that is not the
# atomic it looks like. Wine already writes these guards as
# "__x86_64__ && !__arm64ec__" or "__aarch64__ || __arm64ec__" -- three sites did
# not, and they only bite when a PE is built for arm64ec. The fix belongs in the
# wine fork, but this tree cannot push there, so it is applied here at build time
# exactly as patches/fex-ios-arm64-mbi.patch is. A patch that neither applies nor
# is already applied is fatal: skipping it would leave the arm64ec DLLs
# unbuildable and the failure would surface as a link error far from the cause.
WINE_ARM64EC_PATCH="$REPO_ROOT/patches/wine-arm64ec-inline-asm.patch"
if git -C "$WINE_SRC" apply --check "$WINE_ARM64EC_PATCH" 2>/dev/null; then
    git -C "$WINE_SRC" apply "$WINE_ARM64EC_PATCH"
    echo "Applied Wine arm64ec inline-asm patch."
elif git -C "$WINE_SRC" apply --reverse --check "$WINE_ARM64EC_PATCH" 2>/dev/null; then
    echo "Wine arm64ec inline-asm patch already applied."
else
    echo "ERROR: $WINE_ARM64EC_PATCH neither applies nor is already applied;" >&2
    echo "       rebase it onto wine $(git -C "$WINE_SRC" rev-parse --short HEAD)." >&2
    exit 1
fi

# Re-run configure even after cache restoration: config.h alone says nothing
# about the source revision, selected architecture, SDK or generated IDL headers.
configure_wine_tree() {
    local build="$1" archs="$2" log="$3"
    mkdir -p "$build"
    (
        cd "$build"
        # Wine's build tools execute on macOS, but the compiler is invoked by its
        # absolute Xcode path, which carries no default sysroot: without an
        # explicit -isysroot even <stdio.h> is missing (CI: tools/widl failed
        # after configure itself passed — its probe program needs no headers).
        # A bare exported SDKROOT does not fix it, and subshell exports would not
        # reach the make steps below this block anyway. So resolve the SDK once,
        # verify it up front (seconds, not minutes), and bake -isysroot into the
        # flags configure records in its Makefiles — configure tests and make
        # then compile and link against the same SDK.
        MACOS_SDK="$(xcrun --sdk macosx --show-sdk-path)"
        if [[ -z "$MACOS_SDK" || ! -d "$MACOS_SDK" ]]; then
            echo "ERROR: macOS SDK not found (xcrun returned '${MACOS_SDK:-<empty>}')." >&2
            exit 1
        fi
        if [[ ! -f "$MACOS_SDK/usr/include/stdio.h" ]]; then
            echo "ERROR: macOS SDK has no usr/include/stdio.h: $MACOS_SDK" >&2
            exit 1
        fi
        echo "macOS SDK: $MACOS_SDK ($(xcrun --sdk macosx --show-sdk-version)), --enable-archs=$archs"
        SYSROOT_FLAGS="-isysroot $MACOS_SDK"
        # Preserve configure's actual compiler/linker diagnostic on failure.
        trap 'status=$?; if [[ $status -ne 0 && -f config.log ]]; then cat config.log >&2; fi; exit "$status"' EXIT
        CC="$(xcrun --sdk macosx --find clang)" \
        CXX="$(xcrun --sdk macosx --find clang++)" \
        CFLAGS="${CFLAGS:-} $SYSROOT_FLAGS" \
        CPPFLAGS="${CPPFLAGS:-} $SYSROOT_FLAGS" \
        LDFLAGS="${LDFLAGS:-} $SYSROOT_FLAGS" \
        ../configure --enable-win64 --enable-archs="$archs" --with-mingw=llvm-mingw \
            --without-x --without-freetype --without-vulkan --disable-tests \
            --prefix=/tmp/wine-ios
    ) 2>&1 | tee "$REPO_ROOT/$log"
}

# PE/COFF libraries, not the iOS Mach-O archives. Always rebuild their final
# outputs so old scaffolding archives/scripts cannot satisfy make.
build_wine_pe_libs() {
    local build="$1" log="$2" target members
    shift 2
    local targets=("$@")
    for target in "${targets[@]}"; do rm -f "$build/$target"; done
    make -C "$build" -j"$JOBS" "${targets[@]}" 2>&1 | tee "$REPO_ROOT/$log"
    "$build/tools/winebuild/winebuild" --version
    for target in "${targets[@]:1}"; do
        # llvm-ar must be able to read actual members; eight-byte placeholders fail.
        members="$("$MINGW_DIR/bin/llvm-ar" t "$build/$target")"
        [[ -n "$members" ]] || { echo "ERROR: empty Wine PE archive: $target" >&2; exit 1; }
    done
}

# One tree per PE architecture, and never aarch64 together with arm64ec. With
# both enabled Wine treats the pair as an ARM64X build: makedep sets
# native_archs[arm64ec] and hybrid_archs[aarch64], so libwinecrt0.a is emitted
# only as aarch64-windows/ (holding both object sets) and
# arm64ec-windows/libwinecrt0.a is not a target at all -- the build dies with
# "No rule to make target". DXMT looks the arm64ec imports up under the
# per-architecture names, so arm64ec needs its own tree, the way the shipped
# arm64ec DLLs were originally built in wine/build-arm64ec.
configure_wine_tree "$WINE_BUILD" aarch64 wine-configure.log
make -C "$WINE_BUILD" -j"$JOBS" include/all 2>&1 | tee "$REPO_ROOT/wine-headers-build.log"
for header in config.h dwrite.h dwrite_3.h; do
    [[ -s "$WINE_BUILD/include/$header" ]] || { echo "ERROR: generated Wine header missing: $header" >&2; exit 1; }
done
# FreeType takes minutes to rebuild and its outputs are cached alongside the
# native dependencies: skip when the staged archive and headers validate.
if python3 "$REPO_ROOT/tools/validate-ios-bundle.py" --archive "$REPO_ROOT/build/freetype-ios/build/libfreetype.a" >/dev/null 2>&1 \
    && [[ -s "$REPO_ROOT/build/freetype-ios/build/include/freetype/config/ftconfig.h" ]]; then
    echo "FreeType outputs valid — skipping rebuild."
else
    bash "$REPO_ROOT/build/freetype-ios/build.sh" 2>&1 | tee "$REPO_ROOT/freetype-build.log"
fi

if [[ "$DXMT_PE" == 1 ]]; then
    # One set per architecture: DXMT links the arm64ec-windows DLLs against the
    # arm64ec imports, and using the aarch64 set instead produces link errors
    # that look like DXMT bugs rather than a missing import library.
    build_wine_pe_libs "$WINE_BUILD" wine-dxmt-pe-build.log \
        tools/winebuild/winebuild \
        libs/winecrt0/aarch64-windows/libwinecrt0.a \
        dlls/ntdll/aarch64-windows/libntdll.a \
        dlls/dbghelp/aarch64-windows/libdbghelp.a

    configure_wine_tree "$WINE_BUILD_ARM64EC" arm64ec wine-configure-arm64ec.log
    make -C "$WINE_BUILD_ARM64EC" -j"$JOBS" include/all 2>&1 | tee "$REPO_ROOT/wine-headers-build-arm64ec.log"
    build_wine_pe_libs "$WINE_BUILD_ARM64EC" wine-dxmt-pe-build-arm64ec.log \
        tools/winebuild/winebuild \
        libs/winecrt0/arm64ec-windows/libwinecrt0.a \
        dlls/ntdll/arm64ec-windows/libntdll.a \
        dlls/dbghelp/arm64ec-windows/libdbghelp.a
fi
