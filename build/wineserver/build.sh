#!/bin/bash
set -euo pipefail

BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$BUILD_DIR/../.." && pwd)"
WINE_SRC="$REPO_ROOT/wine"
command -v xcrun >/dev/null || { echo "ERROR: Wine iOS builds require macOS with Xcode (xcrun not found)." >&2; exit 1; }
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
APP_LIB="$REPO_ROOT/app/Madeira/libwineserver.a"
SHIMS_DIR="$REPO_ROOT/build/ntdll-unix/shims"
[[ -s "$WINE_SRC/build-macos/include/config.h" ]] || {
    echo "ERROR: generated Wine config.h missing; run scripts/prepare-wine-ios.sh." >&2
    exit 1
}

# Object files and library go in build dir
OBJ_DIR="$BUILD_DIR/obj"
mkdir -p "$OBJ_DIR"

CC_FLAGS=(
    -arch arm64 -isysroot "$SDK" -miphoneos-version-min=17.0 -O2
    -I"$WINE_SRC/include" -I"$WINE_SRC/include/wine"
    -I"$WINE_SRC/build-macos/include"
    -I"$BUILD_DIR" -I"$WINE_SRC/server"
    -I"$SHIMS_DIR"
    -include "$BUILD_DIR/config_ios.h"
    -include stdarg.h
    -include "$BUILD_DIR/unicode_fix.h"
    -include "$BUILD_DIR/wineserver_ios_kill.h"
    -DBINDIR=\"/usr/local/bin\" -DDATADIR=\"/usr/local/share\"
    -D__WINESRC__ -DWINE_IOS=1
    -Dmain=wineserver_main
    # Symbol collisions with win32u are NOT handled via -D macros — that
    # rewrites macro args (e.g. DECL_HANDLER(name)) and breaks struct
    # name concatenation. Renames done post-compile via objcopy below,
    # applied to EVERY .o in libwineserver.a so cross-file refs (e.g.
    # clipboard.c calling send_notify_message defined in queue.c) stay
    # internal to the archive after the renames.
    -Wno-implicit-function-declaration
)

compile_one() {
    local src=$1
    local name=$2
    echo -n "  $name... "
    if xcrun -sdk iphoneos clang "${CC_FLAGS[@]}" -c "$src" -o "$OBJ_DIR/$name.o" 2>"$OBJ_DIR/err-$name.txt"; then
        echo "OK"
    else
        echo "FAILED (see $OBJ_DIR/err-$name.txt)"
        cat "$OBJ_DIR/err-$name.txt"
        return 1
    fi
}

# Patched files: name:source_file:replaces_in_archive
PATCHED_FILES=(
    "wine_log_ios:wine_log_ios.c:wine_log_ios.o"
    "request_ios:request_ios.c:request.o"
    "main_ios:main_ios.c:main.o"
    "mach_ios:mach_ios.c:mach.o"
    "unicode_ios:unicode_ios.c:unicode.o"
    "fd_ios:fd_ios.c:fd.o"
    # Build these patched upstream files directly from the pinned submodule.
    "object:$WINE_SRC/server/object.c:object.o"
    # ml575: async.c carries the free_async_queue UAF fix.
    "async:$WINE_SRC/server/async.c:async.o"
    "process_ios:$WINE_SRC/server/process.c:process.o"
    # Files needing rebuild only because the -Dws_* renames must apply
    # to both definers and callers — fixes 10 symbol collisions with win32u.
    "window:$BUILD_DIR/window_ios.c:window.o"
    "user:$WINE_SRC/server/user.c:user.o"
    "mapping:$BUILD_DIR/mapping_ios.c:mapping.o"
    "class:$WINE_SRC/server/class.c:class.o"
    "region:$WINE_SRC/server/region.c:region.o"
    "queue:$BUILD_DIR/queue_ios.c:queue.o"
    # S2: virtual-desktop input fix (WSF_VISIBLE + input_desktop + cursor.clip
    # in create_desktop) lives in the submodule's winstation.c
    "winstation:$WINE_SRC/server/winstation.c:winstation.o"
    # task#32 Steam: stop_thread Mach-based context capture (iOS signal
    # suspend is dead) lives in the submodule's thread.c
    "thread:$WINE_SRC/server/thread.c:thread.o"
    # ml474 (#79): sock.c now builds from the submodule. Before this entry
    # the archive carried a hand-inserted Jul-10 sock.o (probed, source
    # lost) that every rebuild silently preserved — the #79 TCP-table
    # forensics were reading three-week-old mystery code. The submodule
    # copy adds the [srv-conn]/[tcp-state]/[tcp-enum] probes.
    "sock:$WINE_SRC/server/sock.c:sock.o"
)

echo "=== Building kill wrapper (without kill macro) ==="
echo -n "  wineserver_ios_kill... "
# Compile WITHOUT -include wineserver_ios_kill.h to avoid recursive macro
KILL_FLAGS=(-arch arm64 -isysroot "$SDK" -miphoneos-version-min=17.0 -O2
    -I"$BUILD_DIR" -DWINE_IOS=1 -Wno-implicit-function-declaration)
if xcrun -sdk iphoneos clang "${KILL_FLAGS[@]}" -c "$BUILD_DIR/wineserver_ios_kill.c" -o "$OBJ_DIR/wineserver_ios_kill.o" 2>"$OBJ_DIR/err-kill.txt"; then
    echo "OK"
else
    echo "FAILED"; cat "$OBJ_DIR/err-kill.txt"; exit 1
fi

# Rebuild every server translation unit. The old script only patched a prebuilt
# archive, silently depending on objects that were not reproducible from checkout.
# Accept the old selector names, but always perform a complete rebuild.
case "${1:-all}" in
    all|request|main|mach|unicode) ;;
    *) echo "Usage: $0 [all|request|main|mach|unicode]" >&2; exit 1 ;;
esac
SOURCE_LIST="$OBJ_DIR/server-sources.txt"
python3 - "$WINE_SRC/server/Makefile.in" > "$SOURCE_LIST" <<'PY_SOURCES'
import pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text().replace("\\\n", " ")
match = re.search(r"^SOURCES\s*=([^\n]+)", text, re.M)
if not match:
    raise SystemExit("Cannot read Wine server source list")
sources = [name for name in match[1].split() if name.endswith(".c")]
if not sources or any("/" in name for name in sources):
    raise SystemExit("Unexpected Wine server source list")
print("\n".join(sources))
PY_SOURCES
OBJECTS=("$OBJ_DIR/wineserver_ios_kill.o")
while IFS= read -r source; do
    name="${source%.c}"
    selected="$WINE_SRC/server/$source"
    for entry in "${PATCHED_FILES[@]}"; do
        IFS=: read -r patched_name patched_source replaced <<< "$entry"
        if [[ "$replaced" == "$name.o" ]]; then
            selected="$patched_source"
            [[ "$selected" == /* ]] || selected="$BUILD_DIR/$selected"
            break
        fi
    done
    compile_one "$selected" "$name"
    OBJECTS+=("$OBJ_DIR/$name.o")
done < "$SOURCE_LIST"
compile_one "$BUILD_DIR/wine_log_ios.c" wine_log_ios
OBJECTS+=("$OBJ_DIR/wine_log_ios.o")
# Build into a fresh archive; stale or removed source objects must not survive.
rm -f "$OBJ_DIR/libwineserver.a"
xcrun --sdk iphoneos ar rcs "$OBJ_DIR/libwineserver.a" "${OBJECTS[@]}"

echo "=== Renaming colliding symbols in every .o (objcopy sweep) ==="
# Renames internal-to-archive: extract every .o, rename the 10 symbols
# we know collide with win32u-unix, repackage. Affects definitions AND
# references uniformly, so cross-file calls inside wineserver still
# resolve. Externals (win32u, etc.) only see the ws_-prefixed names.
OBJCOPY="${OBJCOPY:-$(command -v llvm-objcopy || true)}"
if [ -z "$OBJCOPY" ] && command -v brew >/dev/null 2>&1; then
    OBJCOPY="$(brew --prefix llvm)/bin/llvm-objcopy"
fi
if [ ! -x "$OBJCOPY" ]; then
    echo "ERROR: llvm-objcopy is required. Install LLVM and add its bin directory to PATH, or set OBJCOPY." >&2
    exit 1
fi
COLLISIONS=(
    alloc_user_handle free_user_handle get_virtual_screen_rect
    destroy_thread_windows get_window_thread is_desktop_class
    is_message_class is_window_visible mirror_region send_notify_message
    # shared_session: BOTH wineserver and win32u-unix declare it as a
    # common global. Single-process iOS link merges them — last writer
    # wins. win32u's shared_session_init() overwrites with the client-side
    # NtMapViewOfSection result (read-only), making wineserver's writes
    # silently fail since they're going through the client's RO view.
    # Rename wineserver-side to ws_shared_session so each side has its
    # own pointer to its own mapping of the same backing file.
    shared_session
    # user_shared_data: the same defect as shared_session, one layer over.
    # wineserver defines it as a common global and ntdll-unix defines it as
    # initialized data; the single-process link merges them. wineserver's
    # create_user_data_mapping() sets it to a writable alias, then the guest's
    # ntdll init runs virtual_ios.c's `user_shared_data = NULL;
    # NtAllocateVirtualMemory(..., PAGE_READONLY)` over the SAME variable, so
    # the server's pointer starts aiming at the guest's read-only page in the
    # FEX guest band. Unlike shared_session this does not fail silently: the
    # server's next store faults on a PROT_READ page and the main loop wedges
    # forever, which is why the shared clock could never be published and why
    # every process hung in server_init_process() the moment a client
    # connected -- guest ntdll init is exactly when the pointer was stolen.
    user_shared_data
)
RENAME_ARGS=()
for s in "${COLLISIONS[@]}"; do
    RENAME_ARGS+=(--redefine-sym "_${s}=_ws_${s}")
done
TMP_RENAME_DIR="$OBJ_DIR/rename"
rm -rf "$TMP_RENAME_DIR" && mkdir -p "$TMP_RENAME_DIR"
(cd "$TMP_RENAME_DIR" && xcrun --sdk iphoneos ar x "$OBJ_DIR/libwineserver.a")
for f in "$TMP_RENAME_DIR"/*.o; do
    "$OBJCOPY" "${RENAME_ARGS[@]}" "$f"
done
rm "$OBJ_DIR/libwineserver.a"
xcrun --sdk iphoneos ar rcs "$OBJ_DIR/libwineserver.a" "$TMP_RENAME_DIR"/*.o
rm -rf "$TMP_RENAME_DIR"
echo "  symbol rename + repack OK"

echo "Copying to app..."
python3 "$REPO_ROOT/tools/validate-ios-bundle.py" --archive "$OBJ_DIR/libwineserver.a"
cp "$OBJ_DIR/libwineserver.a" "$APP_LIB"
echo "Done! libwineserver.a: $(wc -c < "$APP_LIB" | tr -d ' ') bytes"
