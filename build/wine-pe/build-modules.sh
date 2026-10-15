#!/bin/bash
# Build Wine builtin PE modules (ARM64EC) from the wine submodule and install
# them into the app's DLL farm, stripped of debug info (--strip-debug, which
# reproduces the size of every shipped Wine builtin).
#
#   build/wine-pe/build-modules.sh                  the default list below
#   build/wine-pe/build-modules.sh kernelbase ...   these modules instead
#   DEST=/some/dir build/wine-pe/build-modules.sh   install somewhere else
#   build/wine-pe/build-modules.sh wined3d d3d9-wined3d d3d8 ddraw
#                    the wined3d route: Wine's d3d9 is installed as
#                    d3d9-wined3d.dll (DXMT owns d3d9.dll; "d3d9" is refused)
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
# and GAME_MODULES below: builtins games or their installers import that the
# farm does not have (without one the loader stops with STATUS_DLL_NOT_FOUND
# before the program runs). Every module built here links its delay imports
# as plain imports (see UNDELAY below).
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
# Builtins for games and their installers (the madeira-bcd fork has shipped
# them, built from this submodule the same way, since 2026-09-26):
#   msvcr70-msvcr100, msvcrt20, msvcrt40, msvcirt, msvcp60-msvcp100, msvcp120
#       older VC++ runtimes (Crysis's Bin64\Crysis64.exe stops at a missing
#       MSVCR80.dll); vcomp-vcomp140 are their OpenMP runtimes
#   d3d10, d3d10_1, avifil32, msvfw32
#       Crysis Remastered imports d3d10.dll and avifil32.dll
#   d3dx9_24-d3dx9_42, d3dx10_33-d3dx10_43, d3dx11_42, d3dcompiler_33-d3dcompiler_42,
#   d3dcompiler_46
#       D3DX and the shader compilers of the DirectX redistributable
#   xaudio2_0-xaudio2_9 (2_7 above), x3daudio1_0-x3daudio1_6, xapofx1_1-xapofx1_4
#       XAudio2, X3DAudio and XAPOFX
#   d2d1
#       the Rockstar Games Launcher delay-loads it (drawing its DC render
#       targets on DXMT needs the read-back change proposed for willfaust/wine)
#   wmvcore, winegstreamer
#       the Windows Media Format reader (WMCreateReader, WMCreateSyncReader) and
#       its winegstreamer frontend; tools/check-wine-media-dlls.py checks both in
#       the farm after they are built
#   netprofm
#       the Network List Manager, for services a launcher starts in a game
#       session
GAME_MODULES="msvcr70 msvcr71 msvcr80 msvcr90 msvcr100 msvcrt20 msvcrt40 msvcirt
    msvcp60 msvcp70 msvcp71 msvcp80 msvcp90 msvcp100 msvcp120
    vcomp vcomp90 vcomp100 vcomp110 vcomp120 vcomp140
    d3d10 d3d10_1 avifil32 msvfw32
    d3dx9_24 d3dx9_25 d3dx9_26 d3dx9_27 d3dx9_28 d3dx9_29 d3dx9_30 d3dx9_31 d3dx9_32 d3dx9_33
    d3dx9_34 d3dx9_35 d3dx9_36 d3dx9_37 d3dx9_38 d3dx9_39 d3dx9_40 d3dx9_41 d3dx9_42
    d3dx10_33 d3dx10_34 d3dx10_35 d3dx10_36 d3dx10_37 d3dx10_38 d3dx10_39 d3dx10_40 d3dx10_41
    d3dx10_42 d3dx10_43 d3dx11_42
    d3dcompiler_33 d3dcompiler_34 d3dcompiler_35 d3dcompiler_36 d3dcompiler_37 d3dcompiler_38
    d3dcompiler_39 d3dcompiler_40 d3dcompiler_41 d3dcompiler_42 d3dcompiler_46
    xaudio2_0 xaudio2_1 xaudio2_2 xaudio2_3 xaudio2_4 xaudio2_5 xaudio2_6 xaudio2_8 xaudio2_9
    x3daudio1_0 x3daudio1_1 x3daudio1_2 x3daudio1_3 x3daudio1_4 x3daudio1_5 x3daudio1_6
    xapofx1_1 xapofx1_2 xapofx1_3 xapofx1_4
    d2d1 wmvcore winegstreamer netprofm"
# shellcheck disable=SC2086 # the list is split on purpose
[ $# -gt 0 ] || set -- cryptsp d3dx11_43 msvcp110 msvcr110 xaudio2_7 $GAME_MODULES
[ -x "$STRIP" ] || { echo "llvm-mingw not found at $TC (docs/BUILDING.md)" >&2; exit 1; }

targets=()
names=()   # the installed file name of each target
for m in "$@"; do
    case "$m" in
        ntdll) echo "ntdll: use build/wine-pe/build-ntdll.sh (it also pads the image)" >&2; exit 1 ;;
        # Farm names that are not Wine's here: wine/dlls has these directories too, and
        # building one would replace DXMT's, madeira-d3d12's or FEX's DLL with Wine's.
        d3d9|d3d10core|d3d11|dxgi|d3d12|d3d12core|xtajit64) echo "$m: not a Wine module in the farm (DXMT / madeira-d3d12 / FEX; Wine's d3d9 is d3d9-wined3d)" >&2; exit 1 ;;
        # Wine's d3d9 (on wined3d) ships beside DXMT's d3d9.dll under its own
        # name; madeira.cfg d3d9 = wined3d links it in for a session.
        d3d9-wined3d) targets+=("dlls/d3d9/arm64ec-windows/d3d9.dll"); names+=("d3d9-wined3d.dll"); continue ;;
        */*|.*|"") echo "$m: name a module directory under wine/dlls" >&2; exit 1 ;;
    esac
    [ -f "$R/wine/dlls/$m/Makefile.in" ] || { echo "$m: no wine/dlls/$m/Makefile.in" >&2; exit 1; }
    # The file is the module's MODULE line: windows.gaming.input is a .dll, winecoreaudio.drv is not.
    f="$(sed -n 's/^MODULE[[:space:]]*=[[:space:]]*//p' "$R/wine/dlls/$m/Makefile.in")"
    [ -n "$f" ] || { echo "$m: no MODULE line in wine/dlls/$m/Makefile.in" >&2; exit 1; }
    targets+=("dlls/$m/arm64ec-windows/$f")
    names+=("$f")
done

if [ ! -f "$B/config.status" ]; then
    mkdir -p "$B" && (cd "$B" && ../configure --enable-archs=arm64ec --without-x --disable-tests --enable-winegstreamer)
fi
# widl looks for stdole2.tlb under aarch64-windows/ when it builds an ARM64EC
# typelib import (shell32 and others); this tree builds it into arm64ec-windows/.
mkdir -p "$B/dlls/stdole2.tlb"
[ -e "$B/dlls/stdole2.tlb/aarch64-windows" ] || [ -L "$B/dlls/stdole2.tlb/aarch64-windows" ] \
    || ln -s arm64ec-windows "$B/dlls/stdole2.tlb/aarch64-windows"

# UNDELAY: every module built here links its delay imports as plain imports.
# lld's ARM64EC delay-load helper stub is x64 code inside .text (lea rax,
# __imp_aux_X; jmp __tailMerge), and the JIT-pool copy Madeira runs a hybrid
# module from relocates the delay IAT to the stub's pool address, so the first
# call runs x64 code outside the emulator's executable ranges: NoExec, then an
# unhandled c0000005 (the Rockstar Games Launcher in d2d1's DWriteCreateFactory
# stub). A module is changed only when every DLL it delay-loads is in the farm
# or built in this run; its Makefile.in is restored when the script ends.
# UNDELAY=0 keeps the delay imports.
undelayed=()
restore_makefiles() {
    local m
    for m in "${undelayed[@]+"${undelayed[@]}"}"; do git -C "$R/wine" checkout -- "dlls/$m/Makefile.in"; done
}
trap restore_makefiles EXIT
in_farm() { [ -n "$(find "$DEST" -maxdepth 1 -iname "$1.dll" 2>/dev/null)" ]; }
if [ "${UNDELAY:-1}" != 0 ]; then
    for m in "$@"; do
        mk="$R/wine/dlls/$m/Makefile.in"
        delayed="$(sed -n 's/^DELAYIMPORTS[[:space:]]*=[[:space:]]*//p' "$mk")"
        [ -n "$delayed" ] && grep -q '^IMPORTS' "$mk" || continue
        ok=1
        for i in $delayed; do
            in_farm "$i" || case " $* " in *" $i "*) ;; *) ok=0 ;; esac
        done
        [ "$ok" = 1 ] || continue
        sed -i.bak -e '/^DELAYIMPORTS[[:space:]]*=/d' -e "s/^\(IMPORTS[[:space:]]*=.*\)\$/\1 $delayed/" "$mk" && rm -f "$mk.bak"
        rm -f "$B/dlls/$m/arm64ec-windows/$(sed -n 's/^MODULE[[:space:]]*=[[:space:]]*//p' "$mk")"   # an earlier link with the delay imports must not satisfy make
        undelayed+=("$m")
    done
    [ ${#undelayed[@]} -eq 0 ] || echo "delay imports linked as plain imports: ${undelayed[*]}"
fi

# The DLL file targets, not dlls/<name>/all: that would also build a module's
# unix side (winegstreamer's needs GStreamer, see build-ntdll.sh).
make -C "$B" -j"$JOBS" "${targets[@]}"

mkdir -p "$DEST"
for i in "${!targets[@]}"; do
    t="${targets[$i]}"
    out="$DEST/${names[$i]}"
    cp "$B/$t" "$out.tmp"
    "$STRIP" --strip-debug "$out.tmp"
    mv "$out.tmp" "$out"
    ls -l "$out"
done

# The Windows Media Format reader needs both DLLs, with plain imports that all
# resolve in the farm.
case " $* " in
    *" wmvcore "*|*" winegstreamer "*) python3 "$R/tools/check-wine-media-dlls.py" "$DEST" ;;
esac
