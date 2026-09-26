#!/bin/bash
# Build the 32-bit (i386) Windows farm that WoW64 sessions load:
# app/Madeira/i386-windows/.
#
# This is the macOS form of the WSL stage script the 32-bit work was built
# with. It follows the conventions of build/wine-pe/build-ntdll.sh (the
# llvm-mingw toolchain under toolchains/, a separate wine/build-<arch> tree) and
# has NOT been run on macOS yet: the logic is the WSL script's, the paths and
# tool invocations are translated. See docs/WOW64.md, "Building".
#
#   build/wine-i386/build.sh                 whole farm + DXMT's i386 DLLs
#   build/wine-i386/build.sh kernel32 user32 only those Wine modules
#   SKIP_DXMT=1 build/wine-i386/build.sh     Wine modules only
#
# What goes in, and why it is not a hand-written list: a 32-bit program that
# imports one missing DLL never reaches its first instruction
# ("import_dll Library FOO.dll ... not found"), and there is no way to find the
# gap except by running that exact program. So the farm is EVERY module this
# configured i386 tree has a rule for, minus the SKIP list below, each entry
# with its reason. The import-closure report at the end names anything still
# missing.
#
# DXMT owns d3d11/dxgi/d3d10core/winemetal on i386 as on 64-bit: Wine's own
# d3d11/dxgi/d3d10core are wined3d frontends and wined3d has no backend in this
# port (no OpenGL, --without-vulkan), so those are never installed from Wine.
# d3d9 is left to the D3D9 series (DXMT's frontend + shim); Wine's copy is not
# installed either.
set -euo pipefail

R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TC="$R/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin"
export PATH="$TC:$PATH"
B="$R/wine/build-i386"
DEST="$R/app/Madeira/i386-windows"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 8)}"
STRIP="$TC/i686-w64-mingw32-strip"
OBJDUMP="$TC/llvm-objdump"
LOG="$B/madeira-i386-build.log"

[ -x "$STRIP" ] || { echo "llvm-mingw not found at $TC (docs/BUILDING.md)" >&2; exit 1; }

# ---------------------------------------------------------------- configure
# Its own tree, like build-arm64ec: reconfiguring build-macos with an extra
# arch would regenerate every module Makefile the ntdll-unix build relies on.
if [ ! -f "$B/config.status" ]; then
    mkdir -p "$B"
    (cd "$B" && ../configure --enable-archs=i386 --without-x --without-vulkan \
                             --without-freetype --without-gnutls --disable-tests)
fi

# ------------------------------------------------------------------ targets
EXT_RE='\.(dll|exe|drv|cpl|acm|ax|ocx|tlb|msstyles|com)$'
# 16-bit modules (.dll16/.exe16/...) fall out of EXT_RE: WoW64 has no NE loader.
SKIP_REASON=(
  "cng.sys|fltmgr.sys|hidclass.sys|hidparse.sys|http.sys|ksecdd.sys|mouhid.sys|mountmgr.sys|ndis.sys|netio.sys|nsiproxy.sys|scsiport.sys|tdi.sys|usbd.sys|winebth.sys|winebus.sys|winehid.sys|winexinput.sys|wmilib.sys=kernel drivers; under WoW64 drivers are 64-bit only"
  "ntoskrnl.exe|winedevice.exe=the driver world (see .sys)"
  "xtajit.dll|xtajit64.dll|wow64.dll|wow64win.dll|wow64cpu.dll=64-bit side of WoW64, never i386"
  "winemac.drv=macOS display driver; the display goes through win32u + Winios"
  "wineps.drv=PostScript/CUPS; no CUPS unix side on iOS"
  "winevulkan.dll|vulkan-1.dll=tree is --without-vulkan; graphics go through DXMT"
  "opencl.dll|wpcap.dll=wrappers over host unix libraries that are not built for iOS"
  "wow32.dll|winevdm.exe|vga.dll|hal.dll|w32skrnl.dll=16-bit layer; no 16-bit modules in a WoW64 tree"
  "winemenubuilder.exe=writes host desktop menu entries; there is no host desktop"
  "wineconsole.exe=host console; conhost is the WoW64-side console"
  "winegstreamer.dll|ir50_32.dll=media has its own series (the unix side is not in this tree)"
  "aero.msstyles=7.4 MiB of theme data nothing in the prefix selects"
  "winedbg.exe=4.5 MiB debugger only the (unshown) crash dialog spawns; dbghelp.dll ships"
  "d3d11.dll|dxgi.dll|d3d10core.dll|winemetal.dll=DXMT-owned (installed below); Wine's are wined3d frontends with no backend here"
  "d3d9.dll=DXMT-owned, installed by the D3D9 series"
)
SKIP=()
for e in "${SKIP_REASON[@]}"; do IFS='|' read -r -a n <<< "${e%%=*}"; SKIP+=("${n[@]}"); done
is_in() { local x="$1"; shift; for y in "$@"; do [ "$x" = "$y" ] && return 0; done; return 1; }

TARGETS=()
while IFS= read -r t; do
    b="$(basename "$t")"
    is_in "$b" "${SKIP[@]}" && continue
    if [ $# -gt 0 ]; then
        want=0
        for a in "$@"; do [ "$b" = "$a" ] || [ "${b%.*}" = "$a" ] && want=1; done
        [ "$want" = 1 ] || continue
    fi
    TARGETS+=("$t")
done < <(grep -oE '^(dlls|programs)/[^/]+/i386-windows/[^/ :]+' "$B/Makefile" | grep -E "$EXT_RE" | sort -u)
[ ${#TARGETS[@]} -gt 0 ] || { echo "no i386 targets matched" >&2; exit 2; }
echo "== ${#TARGETS[@]} i386 modules (skipped by policy: ${#SKIP[@]} names) =="

# -------------------------------------------------------------------- build
cd "$B"
set +e
make -k -j"$JOBS" "${TARGETS[@]}" > "$LOG" 2>&1
set -e
FAILED=()
for t in "${TARGETS[@]}"; do
    [ -f "$t" ] && continue
    if ! make -j1 "$t" >> "$LOG" 2>&1 || [ ! -f "$t" ]; then FAILED+=("$t"); fi
done
if [ ${#FAILED[@]} -gt 0 ]; then
    printf 'FAIL %s\n' "${FAILED[@]}"
    echo "== ${#FAILED[@]} modules failed; nothing installed (log: $LOG) =="
    exit 1
fi

mkdir -p "$DEST"
for t in "${TARGETS[@]}"; do
    b="$(basename "$t")"
    cp -f "$t" "$DEST/$b.tmp"
    case "$b" in *.tlb) ;; *) "$STRIP" --strip-debug "$DEST/$b.tmp" ;; esac
    mv -f "$DEST/$b.tmp" "$DEST/$b"
done
echo "== installed ${#TARGETS[@]} Wine modules into app/Madeira/i386-windows =="

# --------------------------------------------------------------------- DXMT
# The i386 build of research/dxmt (d3d11/dxgi/d3d10core/winemetal), linked
# against this tree's import libraries. winemetal's wow64 thunk table on the
# unix side is what lets these 32-bit DLLs reach the Metal renderer.
if [ -z "${SKIP_DXMT:-}" ] && [ $# -eq 0 ]; then
    D="$R/research/dxmt"
    X="$B/dxmt-cross-i386.txt"
    cat > "$X" <<EOF
[binaries]
c = '$TC/i686-w64-mingw32-clang'
cpp = '$TC/i686-w64-mingw32-clang++'
ar = '$TC/i686-w64-mingw32-ar'
strip = '$TC/i686-w64-mingw32-strip'
windres = '$TC/i686-w64-mingw32-windres'
dlltool = '$TC/i686-w64-mingw32-dlltool'

[properties]
needs_exe_wrapper = true

[host_machine]
system = 'windows'
cpu_family = 'x86'
cpu = 'i686'
endian = 'little'
EOF
    cd "$D"
    if [ ! -f build-pe-i386/build.ninja ]; then
        SDKROOT="$(xcrun --sdk macosx --show-sdk-path)" \
        meson setup --cross-file "$X" --native-file build-osx.txt --buildtype release \
            -Dwine_build_path="$B" -Dwine_builtin_dll=true build-pe-i386
    fi
    SDKROOT="$(xcrun --sdk macosx --show-sdk-path)" meson compile -C build-pe-i386
    for m in d3d11/d3d11.dll dxgi/dxgi.dll d3d10/d3d10core.dll winemetal/winemetal.dll; do
        "$STRIP" -o "$DEST/$(basename "$m")" "build-pe-i386/src/$m"
    done
    echo "== installed DXMT i386 d3d11/dxgi/d3d10core/winemetal =="
fi

# ----------------------------------------------------------- import closure
# Every DLL an installed module imports must be in the farm (api-ms-win-* is
# resolved through apisetschema.dll, which the breadth set includes).
missing=0
present="$(ls "$DEST" | tr '[:upper:]' '[:lower:]')"
for f in "$DEST"/*; do
    case "$f" in *.tlb) continue ;; esac
    while IFS= read -r imp; do
        l="$(echo "$imp" | tr '[:upper:]' '[:lower:]')"
        case "$l" in api-ms-win-*|ext-ms-win-*) continue ;; esac
        echo "$present" | grep -qx "$l" && continue
        echo "missing import: $(basename "$f") -> $imp"; missing=$((missing + 1))
    done < <("$OBJDUMP" -p "$f" 2>/dev/null | sed -n 's/^ *DLL Name: //p')
done
echo "== $(ls "$DEST" | wc -l | tr -d ' ') files in app/Madeira/i386-windows, $missing missing imports =="
