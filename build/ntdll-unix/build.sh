#!/bin/bash
set -e

BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$BUILD_DIR/../.." && pwd)"
WINE_SRC="$REPO_ROOT/wine"
WINE_BUILD="$WINE_SRC/build-macos"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
OBJ_DIR="$BUILD_DIR/obj"
APP_LIB="$REPO_ROOT/app/Madeira/libntdll_unix.a"

mkdir -p "$OBJ_DIR"

# Optional Vulkan route; do not change the normal native build.
VULKAN_FLAGS=()
if [ "${MADEIRA_MOLTENVK:-0}" = 1 ]; then
    VULKAN_FLAGS=(-DMADEIRA_MOLTENVK=1)
fi

# Detect optional diagnostic fields in the SDK used for this target build.
# Keep SDK versions without this member buildable; it is not a runtime requirement.
RUSAGE_PAGE_WAIT_FLAGS=()
if printf '#include <sys/resource.h>\nvoid probe(struct rusage_info_v6 *r) { (void)r->ri_page_wait_time_mach; }\n' | \
    xcrun -sdk iphoneos clang -arch arm64 -isysroot "$SDK" \
        -miphoneos-version-min=17.0 -x c -fsyntax-only - >/dev/null 2>&1; then
    RUSAGE_PAGE_WAIT_FLAGS=(-DMADEIRA_HAVE_RUSAGE_PAGE_WAIT_TIME_MACH=1)

fi

SUCCEEDED=0
FAILED=0
FAILED_FILES=""

compile_one() {
    local src=$1
    local name=$2
    shift 2   # anything after src and name: extra flags for this file only
    echo -n "  $name... "

    if xcrun -sdk iphoneos clang \
        -arch arm64 -isysroot "$SDK" -miphoneos-version-min=17.0 \
        -O2 -fPIC -fvisibility=hidden -fno-stack-protector -fno-strict-aliasing \
        "${VULKAN_FLAGS[@]}" \
        -Wno-implicit-function-declaration -Wno-int-conversion \
        -include "$WINE_BUILD/include/config.h" \
        -include "$BUILD_DIR/shims/wine_ios_exit.h" \
        -I"$BUILD_DIR/shims" -I"$BUILD_DIR/../madsync" -DHAVE_LINUX_NTSYNC_H=1 \
        -I"$WINE_BUILD/dlls/ntdll" -I"$WINE_SRC/dlls/ntdll" -I"$WINE_SRC/dlls/ntdll/unix" \
        -I"$WINE_BUILD/include" -I"$WINE_SRC/include" \
        -D__WINESRC__ -DLTC_NO_PROTOTYPES -DLTC_SOURCE -D_NTSYSTEM_ \
        -D_ACRTIMP= -DWINBASEAPI= \
        -DBINDIR=\"/usr/local/bin\" -DLIBDIR=\"/usr/local/lib\" \
        -DDATADIR=\"/usr/local/share\" -DSYSTEMDLLPATH=\"\" \
        -DWINE_UNIX_LIB -DWINE_IOS=1 \
        "${RUSAGE_PAGE_WAIT_FLAGS[@]}" \
        -Dget_thread_context=ntdll_get_thread_context \
        -Dset_thread_context=ntdll_set_thread_context \
        "$@" \
        -c "$src" -o "$OBJ_DIR/$name.o" 2>"$OBJ_DIR/$name.err"; then
        echo "OK"
        SUCCEEDED=$((SUCCEEDED + 1))
    else
        echo "FAILED"
        FAILED=$((FAILED + 1))
        FAILED_FILES="$FAILED_FILES $name"
        case "$name" in
            io_status_abi|file|socket|loader|server|thread|process|virtual|signal_arm64)
                python3 - "$OBJ_DIR/$name.err" <<'PYCODE'
import sys
from pathlib import Path
for line in [s for s in Path(sys.argv[1]).read_text(errors='replace').splitlines() if 'error:' in s][:8]:
    print('::error::' + line.replace('%', '%25').replace('\r', '%0D'))
PYCODE
                echo "Required IOSB ABI consumer failed: $name; refusing a stale object" >&2
                exit 1
                ;;
        esac
    fi
}

# iOS-Madeira 2026-07-05 (Steam S0): compile a DLL's unix side into
# libntdll_unix.a. Args: src, obj-name, funcs-prefix, extra flags...
# The __wine_unix_call_funcs tables are renamed per-lib (they'd collide
# in one archive) and registered by name in virtual_ios.c's
# load_builtin_unixlib. GnuTLS-backed libs add ios_gnutls_shim.h to
# route dlopen/dlsym at the static symtab (gnutls_symtab_ios.c).
CRYPTO_DIR="$REPO_ROOT/build/crypto-unix"
GNUTLS_PREFIX="$REPO_ROOT/toolchains/gnutls-ios"
compile_unixlib() {
    local src=$1 name=$2 prefix=$3
    shift 3
    echo -n "  $name... "
    if xcrun -sdk iphoneos clang \
        -arch arm64 -isysroot "$SDK" -miphoneos-version-min=17.0 \
        -O2 -fPIC -fvisibility=hidden -fno-stack-protector -fno-strict-aliasing \
        "${VULKAN_FLAGS[@]}" \
        -Wno-implicit-function-declaration -Wno-int-conversion \
        -include "$WINE_BUILD/include/config.h" \
        -include "$BUILD_DIR/shims/wine_ios_exit.h" \
        -I"$BUILD_DIR/shims" -I"$BUILD_DIR/../madsync" -DHAVE_LINUX_NTSYNC_H=1 \
        -I"$WINE_BUILD/include" -I"$WINE_SRC/include" \
        -D__WINESRC__ -D_NTSYSTEM_ -D_ACRTIMP= -DWINBASEAPI= \
        -DWINE_UNIX_LIB -DWINE_IOS=1 \
        -D__wine_unix_call_funcs=${prefix}_unix_call_funcs \
        -D__wine_unix_call_wow64_funcs=${prefix}_unix_call_wow64_funcs \
        "$@" \
        -c "$src" -o "$OBJ_DIR/$name.o" 2>"$OBJ_DIR/$name.err"; then
        echo "OK"
        SUCCEEDED=$((SUCCEEDED + 1))
    else
        echo "FAILED"
        FAILED=$((FAILED + 1))
        FAILED_FILES="$FAILED_FILES $name"
    fi
}

echo "=== Building ntdll unix (iOS) ==="

# iOS-Madeira 2026-05-13: silent audio driver — provides a null
# IAudioClock that advances at real time so FMOD's audio-gated rhythm
# logic in Thumper et al. advances past intro music.
compile_one "$BUILD_DIR/audio_null_ios.c" "audio_null_ios"
test -f "$WINE_SRC/include/wine/ios_io_abi.h" || { echo "Missing IOSB ABI overlay" >&2; exit 1; }
compile_one "$BUILD_DIR/io_status_abi.c" "io_status_abi"
compile_one "$BUILD_DIR/../madsync/madsync.c" "madsync"   # ml1058: userspace ntsync

# iOS-Madeira 2026-07-05 (Steam S0): network + crypto unix sides.
echo "=== Building crypto/network unixlibs ==="
"$CRYPTO_DIR/gen_gnutls_symtab.sh" > /dev/null
compile_one "$CRYPTO_DIR/gnutls_symtab_ios.c" "gnutls_symtab_ios"
compile_unixlib "$WINE_SRC/dlls/ws2_32/unixlib.c" "ws2_32_unixlib" "ws2_32" \
    -I"$WINE_SRC/dlls/ws2_32"
# madeira-gnutls-unixlibs: the host configure cannot detect an iOS arm64 static
# archive, so config.h leaves HAVE_GNUTLS_CIPHER_INIT and SONAME_LIBGNUTLS
# undefined and all three sources below compile to empty objects. The iOS chain
# links GnuTLS statically regardless (see ios_gnutls_shim.h), so define them
# here -- on these three translation units only, because the host build really
# does not have GnuTLS and config.h should keep saying so.
#
# Warns rather than fails when the prefix is absent, so a tree that has never
# run build/gnutls-ios/build.sh still builds exactly as it does today -- it
# just keeps getting the empty objects, and now says so instead of leaving it
# to be discovered by a program whose HTTPS request goes nowhere.
GNUTLS_DEFS=()
if [ -f "$GNUTLS_PREFIX/lib/libgnutls.a" ]; then
    GNUTLS_DEFS=(-DHAVE_GNUTLS_CIPHER_INIT '-DSONAME_LIBGNUTLS="libgnutls.so.30"')
else
    echo "WARNING: $GNUTLS_PREFIX/lib/libgnutls.a is missing, so bcrypt," >&2
    echo "         secur32 and crypt32 compile to empty objects and guest-side" >&2
    echo "         TLS will not work. Run build/gnutls-ios/build.sh to fix." >&2
fi

compile_unixlib "$WINE_SRC/dlls/bcrypt/gnutls.c" "bcrypt_unixlib" "bcrypt" \
    -I"$WINE_SRC/dlls/bcrypt" -I"$GNUTLS_PREFIX/include" \
    -include "$CRYPTO_DIR/ios_gnutls_shim.h" \
    "${GNUTLS_DEFS[@]}"
compile_unixlib "$WINE_SRC/dlls/secur32/schannel_gnutls.c" "secur32_unixlib" "secur32" \
    -I"$WINE_SRC/dlls/secur32" -I"$GNUTLS_PREFIX/include" \
    -include "$CRYPTO_DIR/ios_gnutls_shim.h" \
    "${GNUTLS_DEFS[@]}"
# iOS-Madeira ml494 (#61 text wall): dwrite had NO unixlib, so every
# __wine_unix_call from dwrite.dll failed and get_glyph_bbox never ran —
# every glyph run reported an EMPTY bbox and Chromium drew no text at all.
# freetype is static here, so dwrite_freetype_ios.c rewrites dlopen/dlsym.
# dwrite.h/dwrite_3.h are widl-generated and only exist in the arm64ec
# build tree, so that include dir is named explicitly here.
compile_unixlib "$BUILD_DIR/dwrite_freetype_ios.c" "dwrite_unixlib" "dwrite" \
    -I"$WINE_SRC/dlls/dwrite" -I"$REPO_ROOT/research/freetype/include" \
    -I"$REPO_ROOT/wine/build-arm64ec/include"
compile_unixlib "$CRYPTO_DIR/crypt32_unixlib_ios.c" "crypt32_unixlib" "crypt32" \
    -I"$WINE_SRC/dlls/crypt32" -I"$GNUTLS_PREFIX/include" \
    -include "$CRYPTO_DIR/ios_gnutls_shim.h" \
    "${GNUTLS_DEFS[@]}"
# OpenGL's pinned Unix thunks still assume guest pointers are host pointers.
# Stage the existing reviewed overlay, including generated pointer thunks,
# without modifying the submodule or downloading a registry at build time.
OPENGL_STAGE="$(mktemp -d)"
trap 'rm -rf "$OPENGL_STAGE"' EXIT
python3 "$REPO_ROOT/tools/build/stage-opengl-wow64.py" "$OPENGL_STAGE"
OPENGL_FAILED_BEFORE=$FAILED
compile_unixlib "$OPENGL_STAGE/dlls/opengl32/unix_wgl.c" "opengl32_wgl" "opengl32" \
    -I"$WINE_SRC/dlls/opengl32"
compile_unixlib "$OPENGL_STAGE/dlls/opengl32/unix_thunks.c" "opengl32_thunks" "opengl32" \
    -I"$WINE_SRC/dlls/opengl32"
if [ "$FAILED" -ne "$OPENGL_FAILED_BEFORE" ]; then
    # Never ship an old object left from a previous build after an overlay
    # compile failure. Keep the actionable diagnostics in Actions annotations.
    python3 - "$OBJ_DIR/opengl32_wgl.err" "$OBJ_DIR/opengl32_thunks.err" <<'PYCODE'
import sys
from pathlib import Path
for path in sys.argv[1:]:
    lines=Path(path).read_text(errors='replace').splitlines()
    for line in [s for s in lines if 'error:' in s][:8]:
        print('::error::'+line.replace('%','%25').replace('\r','%0D'))
PYCODE
    exit 1
fi
rm -rf "$OPENGL_STAGE"
trap - EXIT
# Vulkan: winevulkan's unix side (instance/device wrappers + generated thunks).
# It dispatches to win32u's Vulkan layer (build/win32u-unix/vulkan_ios.c), which
# loads the session's Vulkan library (MADEIRA_VULKAN_LIBRARY; off by default).
# Bound for 64-bit callers only (virtual_ios.c): the wow64 thunks pass 32-bit
# guest pointers through UlongToPtr, without the window base a 32-bit program
# here needs (ios_wow_host_ptr), like opengl32's before its regenerated thunks.
compile_unixlib "$WINE_SRC/dlls/winevulkan/vulkan.c" "winevulkan_vulkan" "winevulkan" \
    -I"$WINE_SRC/dlls/winevulkan"
compile_unixlib "$WINE_SRC/dlls/winevulkan/vulkan_thunks.c" "winevulkan_thunks" "winevulkan" \
    -I"$WINE_SRC/dlls/winevulkan"
# iOS-Madeira 2026-08-03 (#79 transport): in-process NSI TCP connection
# tables (nsiproxy.sys is not shipped; PE nsi.dll falls back to this).
compile_one "$BUILD_DIR/nsi_unixlib_ios.c" "nsi_unixlib_ios"
# iOS-Madeira: the other NSI tables (network interfaces, IP addresses,
# routes) from Wine's own BSD providers, wine/dlls/nsiproxy.sys/ndis.c and
# ip.c, behind nsiproxy.sys's table dispatcher (nsi_network_ios.c).
# shims/net/route.h declares the routing-message ABI they read, which the
# iPhoneOS SDK does not ship.
compile_one "$BUILD_DIR/nsi_network_ios.c" "nsi_network_ios"
compile_one "$BUILD_DIR/nsi_ndis_ios.c" "nsi_ndis"
compile_one "$BUILD_DIR/nsi_ip_ios.c" "nsi_ip"
# dnsapi had no unix side (the generic stub table: every call STATUS_NOT_SUPPORTED,
# including the DNS server list GetAdaptersAddresses asks for). dnsapi_unixlib_ios.c
# is upstream dlls/dnsapi/libresolv.c with res_init/res_query/_res/h_errno rebound to
# /usr/lib/libresolv.9.dylib through dlopen, so nothing is added to the app's link.
compile_unixlib "$BUILD_DIR/dnsapi_unixlib_ios.c" "dnsapi_unixlib" "dnsapi" \
    -I"$WINE_SRC/dlls/dnsapi"
# MADEIRA 2026-09-19: winegstreamer's unix side is GStreamer, which does not
# exist on iOS -- so the Windows WMA decoder MFT (CLSID_CWMADecMediaObject ->
# wmadmod.dll -> CLSID_wg_wma_decoder in winegstreamer.dll) was absent and
# FAudio fed xaudio2's mixer the COMPRESSED xWMA bytes as PCM (the static, and
# the 8x-full-scale peaks in the audio census).  winegstreamer_unixlib_ios.c
# replaces the wg_transform subset that dlls/winegstreamer/wma_decoder.c needs
# with libavcodec, and the wg_parser (quartz's MP3/WAV splitters, Media
# Foundation's MP4 source; wg_parser_av_ios.c, #included by it) with
# libavformat.  FFmpeg comes from build/ffmpeg/build.sh (LGPL configuration).
# The widl-generated mfobjects.h/mftransform.h that unixlib.h pulls in only
# exist in a configured build tree's include dir, which $WINE_BUILD already is.
FFMPEG_PREFIX="$REPO_ROOT/toolchains/ffmpeg-ios"
compile_unixlib "$BUILD_DIR/winegstreamer_unixlib_ios.c" "winegstreamer_unixlib" "winegstreamer" \
    -I"$WINE_SRC/dlls/winegstreamer" -I"$FFMPEG_PREFIX/include"
# MADEIRA ml1990: the wg_parser's H.264/HEVC (VideoToolbox) and AAC
# (AudioToolbox) decoders.  Its own translation unit with NO Wine header --
# CoreFoundation and winnt.h disagree about several names -- so it is compiled
# without the Wine include paths and config.h.  The app target links
# VideoToolbox, CoreMedia, CoreVideo, AudioToolbox and CoreFoundation
# (app/Madeira.xcodeproj, Frameworks phase) next to the FFmpeg archives.
echo -n "  wg_parser_apple_ios... "
if xcrun -sdk iphoneos clang \
    -arch arm64 -isysroot "$SDK" -miphoneos-version-min=17.0 \
    -O2 -fPIC -fvisibility=hidden -fno-stack-protector -fno-strict-aliasing -Wall -Werror=implicit-function-declaration \
    -c "$BUILD_DIR/wg_parser_apple_ios.c" -o "$OBJ_DIR/wg_parser_apple_ios.o" 2>"$OBJ_DIR/wg_parser_apple_ios.err"; then
    echo "OK"
    SUCCEEDED=$((SUCCEEDED + 1))
else
    echo "FAILED"
    FAILED=$((FAILED + 1))
    FAILED_FILES="$FAILED_FILES wg_parser_apple_ios"
fi

for src in $WINE_SRC/dlls/ntdll/unix/*.c; do
    name=$(basename "$src" .c)

    # Use patched versions for specific files
    case "$name" in
        loader)
            compile_one "$BUILD_DIR/loader_ios.c" "loader"
            ;;
        process)
            compile_one "$BUILD_DIR/process_ios.c" "process"
            ;;
        server)
            compile_one "$BUILD_DIR/server_ios.c" "server"
            ;;
        env)
            compile_one "$BUILD_DIR/env_ios.c" "env"
            ;;
        cdrom)
            compile_one "$BUILD_DIR/cdrom_stub.c" "cdrom"
            ;;
        virtual)
            compile_one "$BUILD_DIR/virtual_ios.c" "virtual"
            ;;
        signal_arm64)
            compile_one "$BUILD_DIR/signal_arm64_ios.c" "signal_arm64"
            ;;
        thread)
            compile_one "$BUILD_DIR/thread_ios.c" "thread"
            ;;
        file|socket)
            # Observe the real IOSB publication in both producers. Only the
            # generated translation unit includes this diagnostic wrapper;
            # the pinned Wine source and its ABI remain unchanged.
            python3 - "$src" "$OBJ_DIR/${name}_ios.c" "$BUILD_DIR/io_status_trace.h" <<'PYCODE'
import sys
from pathlib import Path
source, output, header = map(Path, sys.argv[1:])
text = source.read_text()
needle = '#include "unix_private.h"'
if text.count(needle) != 1:
    raise SystemExit('I/O diagnostic include boundary changed')
text = text.replace(needle, needle + '\n#include "' + str(header) + '"')
if source.name == 'file.c':
    # The old tracker inferred file coverage from destination-buffer contiguity
    # and byte sums. Replace only that maintained diagnostic at staging time.
    start = text.index('#define IOS_JSTRACK_MAX 64')
    end = text.index('\n#endif\n\nNTSTATUS WINAPI NtReadFile(', start)
    text = text[:start] + '#include "' + str(header.with_name('js_read_trace.h')) + '"\n' + text[end:]
    boundary = '/* guest-log-test:end */'
    call = '        ios_guest_log_mirror( unix_handle, buffer, total );'
    if text.count(boundary) != 1 or text.count(call) != 1:
        raise SystemExit('CEF log observer boundary changed; refusing stale diagnostics')
    text = text.replace(boundary, boundary + '\n#include "' + str(header.with_name('cef_log_context.h')) + '"')
    text = text.replace(call, call + '\n    if (total) ios_cef_log_observe( unix_handle, buffer, total );')
output.write_text(text)
PYCODE
            IO_FAILED_BEFORE=$FAILED
            compile_one "$OBJ_DIR/${name}_ios.c" "$name"
            if [ "$FAILED" -ne "$IO_FAILED_BEFORE" ]; then
                echo "I/O producer compilation failed; refusing to reuse an old object" >&2
                exit 1
            fi
            ;;
        sync)
            # madeira-bcd: a NULL keyed-event handle resolves per guest process
            # (ios_default_keyed_event, loader_ios.c), not to the first process's
            # global. The copy is compiled from obj/, so its one relative include
            # is made absolute; the build fails if the source no longer matches.
            perl -0pe 's/(NTSTATUS WINAPI NtWaitForKeyedEvent\()/HANDLE ios_default_keyed_event(void);\n$1/;
                       s/if \(!handle\) handle = keyed_event;/if (!handle) handle = ios_default_keyed_event();/g;
                       s{"\.\./\.\./\.\./\.\./build/madeira_cfg\.h"}{"'"$REPO_ROOT"'/build/madeira_cfg.h"}' \
                "$src" > "$OBJ_DIR/sync_ios.c"
            if [ "$(grep -c 'handle = ios_default_keyed_event()' "$OBJ_DIR/sync_ios.c")" != 2 ]; then
                echo "  sync: keyed-event patch did not apply"; exit 1
            fi
            # MADEIRA_THREAD_QOS (thread_ios.c): ios_eco_apply_self sets a guest
            # thread's QoS through madeira_guest_qos_self, which picks the class
            # given for the thread's name; with the variable unset it passes through.
            compile_one "$OBJ_DIR/sync_ios.c" "sync" -Dpthread_set_qos_class_self_np=madeira_guest_qos_self
            ;;
        *)
            compile_one "$src" "$name"
            ;;
    esac
done

echo ""
echo "Results: $SUCCEEDED succeeded, $FAILED failed"
if [ -n "$FAILED_FILES" ]; then
    echo "Failed:$FAILED_FILES"
fi

echo ""
echo "=== Building libntdll_unix.a ==="
ar rcs "$OBJ_DIR/libntdll_unix.a" \
    "$OBJ_DIR/io_status_abi.o" \
    "$OBJ_DIR/audio_null_ios.o" "$OBJ_DIR/madsync.o" "$OBJ_DIR/nsi_unixlib_ios.o" \
    "$OBJ_DIR/nsi_network_ios.o" "$OBJ_DIR/nsi_ndis.o" "$OBJ_DIR/nsi_ip.o" \
    "$OBJ_DIR/gnutls_symtab_ios.o" "$OBJ_DIR/ws2_32_unixlib.o" \
    "$OBJ_DIR/bcrypt_unixlib.o" "$OBJ_DIR/secur32_unixlib.o" "$OBJ_DIR/crypt32_unixlib.o" \
    "$OBJ_DIR/dwrite_unixlib.o" "$OBJ_DIR/dnsapi_unixlib.o" "$OBJ_DIR/opengl32_wgl.o" "$OBJ_DIR/opengl32_thunks.o" \
    "$OBJ_DIR/winevulkan_vulkan.o" "$OBJ_DIR/winevulkan_thunks.o" \
    "$OBJ_DIR/winegstreamer_unixlib.o" "$OBJ_DIR/wg_parser_apple_ios.o" \
    "$OBJ_DIR/cdrom.o" "$OBJ_DIR/debug.o" "$OBJ_DIR/env.o" "$OBJ_DIR/file.o" \
    "$OBJ_DIR/loader.o" "$OBJ_DIR/loadorder.o" "$OBJ_DIR/process.o" "$OBJ_DIR/registry.o" \
    "$OBJ_DIR/security.o" "$OBJ_DIR/serial.o" "$OBJ_DIR/server.o" \
    "$OBJ_DIR/signal_arm.o" "$OBJ_DIR/signal_arm64.o" "$OBJ_DIR/signal_i386.o" "$OBJ_DIR/signal_x86_64.o" \
    "$OBJ_DIR/socket.o" "$OBJ_DIR/sync.o" "$OBJ_DIR/syscall.o" "$OBJ_DIR/system.o" \
    "$OBJ_DIR/tape.o" "$OBJ_DIR/thread.o" "$OBJ_DIR/virtual.o"

echo "Copying to app..."
cp "$OBJ_DIR/libntdll_unix.a" "$APP_LIB"
echo "libntdll_unix.a: $(wc -c < "$APP_LIB" | tr -d ' ') bytes"
echo "Done!"
