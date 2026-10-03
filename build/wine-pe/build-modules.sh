#!/bin/bash
# Build Wine builtin PE modules (ARM64EC) from the wine submodule and install
# them into the app's DLL farm, stripped of debug info (--strip-debug, which
# reproduces the size of every shipped Wine builtin).
#
#   build/wine-pe/build-modules.sh                  the default list below
#   build/wine-pe/build-modules.sh kernelbase ...   these modules instead
#   DEST=/some/dir build/wine-pe/build-modules.sh   install somewhere else
#
# A module is named by its directory under wine/dlls; the file is <name>.dll
# unless the name has its own extension (winecoreaudio.drv). The default list
# is the stock builtins Madeira added to the farm for games (committed like every
# other builtin; this rebuilds them from the submodule):
#   msvcr110, msvcp110, d3dx11_43  Metro 2033 Redux stopped at load with
#                                  c0000135 without them (its PhysX and game
#                                  modules import them)
#   cryptsp                        Xal.Unity (Ori and the Will of the Wisps)
#                                  delay-loads SystemFunction032 from it
#   xaudio2_7                      the prefix registers CLSID_XAudio2 (2.7) at
#                                  system32\xaudio2_7.dll
# Pass the tracked modules a change touches (kernelbase, shell32, xinput1_1 ...
# xinput1_4, ...) to rebuild them. ntdll is padded as well: build-ntdll.sh.
#
# Shares wine/build-arm64ec (and its first-run configure) with build-ntdll.sh.
# Requires the llvm-mingw toolchain (docs/BUILDING.md) and bison 3 for
# tools/wrc (macOS ships 2.3; Homebrew's is used when it is installed).
set -eu
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TC="$R/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin"
export PATH="$TC:$PATH"
if command -v brew >/dev/null 2>&1; then
    BISON_BIN="$(brew --prefix bison 2>/dev/null)/bin"
    [ -x "$BISON_BIN/bison" ] && export PATH="$BISON_BIN:$PATH"
fi
B="$R/wine/build-arm64ec"
DEST="${DEST:-$R/app/Madeira/arm64ec-windows}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 8)}"
STRIP="$TC/arm64ec-w64-mingw32-strip"

case "${1:-}" in
    -h|--help) sed -n '2,/^set -eu/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
esac
[ $# -gt 0 ] || set -- cryptsp d3dx11_43 msvcp110 msvcr110 xaudio2_7
[ -x "$STRIP" ] || { echo "llvm-mingw not found at $TC (docs/BUILDING.md)" >&2; exit 1; }

targets=()
for m in "$@"; do
    case "$m" in
        ntdll) echo "ntdll: use build/wine-pe/build-ntdll.sh (it also pads the image)" >&2; exit 1 ;;
        */*|.*|"") echo "$m: name a module directory under wine/dlls" >&2; exit 1 ;;
    esac
    [ -f "$R/wine/dlls/$m/Makefile.in" ] || { echo "$m: no wine/dlls/$m/Makefile.in" >&2; exit 1; }
    case "$m" in *.*) f="$m" ;; *) f="$m.dll" ;; esac
    targets+=("dlls/$m/arm64ec-windows/$f")
done

if [ ! -f "$B/config.status" ]; then
    mkdir -p "$B" && (cd "$B" && ../configure --enable-archs=arm64ec --without-x --disable-tests --enable-winegstreamer)
fi
# widl looks for stdole2.tlb under aarch64-windows/ when it builds an ARM64EC
# typelib import (shell32 and others); this tree builds it into arm64ec-windows/.
mkdir -p "$B/dlls/stdole2.tlb"
[ -e "$B/dlls/stdole2.tlb/aarch64-windows" ] || [ -L "$B/dlls/stdole2.tlb/aarch64-windows" ] \
    || ln -s arm64ec-windows "$B/dlls/stdole2.tlb/aarch64-windows"

# The DLL file targets, not dlls/<name>/all: that would also build a module's
# unix side (winegstreamer's needs GStreamer, see build-ntdll.sh).
make -C "$B" -j"$JOBS" "${targets[@]}"

mkdir -p "$DEST"
for t in "${targets[@]}"; do
    out="$DEST/$(basename "$t")"
    cp "$B/$t" "$out.tmp"
    "$STRIP" --strip-debug "$out.tmp"
    mv "$out.tmp" "$out"
    ls -l "$out"
done
