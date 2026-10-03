#!/bin/bash
# Build the ARM64EC Wine modules that x64 games and their installers import but
# app/Madeira/arm64ec-windows/ did not ship: older VC++ runtimes, D3DX9/10/11
# and the old d3dcompiler versions, XAudio2/X3DAudio/XAPOFX, WMI, RichEdit and
# the other modules installers load. Same tree and configure line as
# build/wine-pe/build-ntdll.sh (wine/build-arm64ec).
#
#   build/wine-pe/build-extra-dlls.sh                   the whole list
#   build/wine-pe/build-extra-dlls.sh riched20 msftedit only those modules
#
# A module already in the farm is never rebuilt or replaced (case-insensitive,
# so X3DAudio1_7.dll counts): update a shipped DLL by hand as before.
# Each built DLL is stripped and padded with zeros to SizeOfImage + PAD
# (default 0x10000, what the hand-built modules in the farm have; PAD=0 skips
# the padding). A module that fails is reported and not installed; the others
# are. The import report at the end names any import the farm cannot satisfy.
# TC, WINE_BUILD, DEST, JOBS and PAD override the defaults below.
set -euo pipefail

R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TC="${TC:-$R/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin}"
export PATH="$TC:$PATH"
B="${WINE_BUILD:-$R/wine/build-arm64ec}"
DEST="${DEST:-$R/app/Madeira/arm64ec-windows}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 8)}"
PAD="${PAD:-0x10000}"
STRIP="$TC/arm64ec-w64-mingw32-strip"
OBJDUMP="$TC/llvm-objdump"
LOG="$B/madeira-extra-dlls.log"

[ -x "$STRIP" ] || { echo "llvm-mingw not found at $TC (docs/BUILDING.md)" >&2; exit 1; }

# What goes in, and why. Wine's i386 farm already has all of these (it is every
# module); the arm64ec farm is hand-picked, so a missing one stops an x64
# program at load time ("Library FOO.dll ... not found").
WANT=(
  # VC++ 2002-2013 runtimes (Crysis's Bin64\Crysis64.exe imports msvcr80).
  # msvcr70-msvcr110 need the wine change "msvcr70-110 iOS: mirror writable
  # data into the PE mapping at process attach": without it an x64 program that
  # reads _acmdln/__argv/_environ through its import table sees NULL.
  msvcr70 msvcr71 msvcr80 msvcr90 msvcr100 msvcr110 msvcrt20 msvcrt40 msvcirt
  msvcp60 msvcp70 msvcp71 msvcp80 msvcp90 msvcp100 msvcp110 msvcp120
  vcomp vcomp90 vcomp100 vcomp110 vcomp120 vcomp140
  # Graphics, video, input.
  d3d10 d3d10_1 avifil32 msvfw32 dinput
  d3dx9_24 d3dx9_25 d3dx9_26 d3dx9_27 d3dx9_28 d3dx9_29 d3dx9_30 d3dx9_31
  d3dx9_32 d3dx9_33 d3dx9_34 d3dx9_35 d3dx9_36 d3dx9_37 d3dx9_38 d3dx9_39
  d3dx9_40 d3dx9_41 d3dx9_42
  d3dx10_33 d3dx10_34 d3dx10_35 d3dx10_36 d3dx10_37 d3dx10_38 d3dx10_39
  d3dx10_40 d3dx10_41 d3dx10_42 d3dx10_43
  d3dx11_42 d3dx11_43
  d3dcompiler_33 d3dcompiler_34 d3dcompiler_35 d3dcompiler_36 d3dcompiler_37
  d3dcompiler_38 d3dcompiler_39 d3dcompiler_40 d3dcompiler_41 d3dcompiler_42
  d3dcompiler_46
  # Audio.
  xaudio2_0 xaudio2_1 xaudio2_2 xaudio2_3 xaudio2_4 xaudio2_5 xaudio2_6
  xaudio2_7 xaudio2_8 xaudio2_9
  x3daudio1_0 x3daudio1_1 x3daudio1_2 x3daudio1_3 x3daudio1_4 x3daudio1_5
  x3daudio1_6 x3daudio1_7
  xapofx1_1 xapofx1_2 xapofx1_3 xapofx1_4 xapofx1_5
  # WMI (a GPU requirement check through Win32_VideoController); the bridge
  # links these into system32\wbem, where WMI's CLSIDs point.
  wbemprox wbemdisp wmiutils
  # Installers: the Rockstar Games SDK / Launcher installers load Msftedit.dll,
  # then riched20.dll and gdiplus.dll.
  riched20 riched32 msftedit gdiplus mlang usp10 cabinet sspicli msxml3 msxml6
  # Loaded by GTA V Enhanced's launcher / Social Club.
  msasn1 wldp hnetcfg msctf xmllite
)

# ---------------------------------------------------------------- configure
if [ ! -f "$B/config.status" ]; then
    mkdir -p "$B" && (cd "$B" && "$R/wine/configure" --enable-archs=arm64ec --without-x \
                                       --disable-tests --enable-winegstreamer)
fi
# widl looks for imported typelibs (stdole2.tlb) under <module>/aarch64-windows,
# its arch dir for ARM64EC (get_arch_dir in wine/tools/tools.h), but this
# arm64ec-only tree builds them under arm64ec-windows: without the link
# riched20, hnetcfg and wbemdisp fail with "cannot find stdole2.tlb".
mkdir -p "$B/dlls/stdole2.tlb"
[ -e "$B/dlls/stdole2.tlb/aarch64-windows" ] || ln -s arm64ec-windows "$B/dlls/stdole2.tlb/aarch64-windows"

# ------------------------------------------------------------------ targets
shipped="$(ls "$DEST" | tr '[:upper:]' '[:lower:]')"
MODS=(); TARGETS=(); SKIPPED=0
for m in "${WANT[@]}"; do
    if [ $# -gt 0 ]; then
        want=0
        for a in "$@"; do if [ "$m" = "$a" ]; then want=1; fi; done
        [ "$want" = 1 ] || continue
    fi
    t="dlls/$m/arm64ec-windows/$m.dll"
    grep -q "^$t:" "$B/Makefile" || { echo "no rule for $t in this wine tree, skipped"; continue; }
    if grep -qxF "$m.dll" <<< "$shipped"; then SKIPPED=$((SKIPPED + 1)); continue; fi
    MODS+=("$m"); TARGETS+=("$t")
done
[ ${#MODS[@]} -gt 0 ] || { echo "nothing to build ($SKIPPED already in the farm)"; exit 0; }
echo "== ${#MODS[@]} arm64ec modules to build ($SKIPPED already in the farm) =="

# -------------------------------------------------------------------- build
cd "$B"
set +e
make -k -j"$JOBS" "${TARGETS[@]}" > "$LOG" 2>&1
set -e
for t in "${TARGETS[@]}"; do
    [ -f "$t" ] || make -j1 "$t" >> "$LOG" 2>&1 || true
done

# ------------------------------------------------------------------ install
FAILED=(); INSTALLED=()
for m in "${MODS[@]}"; do
    t="dlls/$m/arm64ec-windows/$m.dll"
    [ -f "$t" ] || { FAILED+=("$m"); continue; }
    cp -f "$t" "$DEST/$m.dll.tmp"
    "$STRIP" "$DEST/$m.dll.tmp"
    python3 - "$DEST/$m.dll.tmp" "$PAD" <<'PY'
import struct, sys
p = sys.argv[1]; pad = int(sys.argv[2], 0); d = open(p, 'rb').read()
pe = struct.unpack_from('<I', d, 0x3c)[0]
target = struct.unpack_from('<I', d, pe + 24 + 56)[0] + pad   # OptionalHeader.SizeOfImage
if pad and len(d) < target:
    open(p, 'ab').write(b'\0' * (target - len(d)))
PY
    mv -f "$DEST/$m.dll.tmp" "$DEST/$m.dll"
    INSTALLED+=("$m.dll")
done
echo "== installed ${#INSTALLED[@]} modules into ${DEST#$R/} =="

# ----------------------------------------------------------- import closure
# Imports of the newly installed modules that the farm cannot satisfy
# (api-ms-win-* resolves through apisetschema.dll).
present="$(ls "$DEST" | tr '[:upper:]' '[:lower:]')"
missing=0
for f in ${INSTALLED[@]+"${INSTALLED[@]}"}; do
    while IFS= read -r imp; do
        l="$(printf %s "$imp" | tr '[:upper:]' '[:lower:]')"
        case "$l" in api-ms-win-*|ext-ms-win-*) continue ;; esac
        grep -qxF "$l" <<< "$present" && continue
        echo "missing import: $f -> $imp"; missing=$((missing + 1))
    done < <("$OBJDUMP" -p "$DEST/$f" 2>/dev/null | sed -n 's/^ *DLL Name: //p')
done
echo "== $missing missing imports =="

if [ ${#FAILED[@]} -gt 0 ]; then
    echo "== ${#FAILED[@]} modules failed (log: $LOG): ${FAILED[*]} =="
    exit 1
fi
