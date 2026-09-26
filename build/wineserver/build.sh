#!/bin/bash
set -e

BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$BUILD_DIR/../.." && pwd)"
WINE_SRC="$REPO_ROOT/wine"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
APP_LIB="$REPO_ROOT/app/Madeira/libwineserver.a"
SHIMS_DIR="$REPO_ROOT/build/ntdll-unix/shims"

# Object files and library go in build dir
OBJ_DIR="$BUILD_DIR/obj"
mkdir -p "$OBJ_DIR"

# Copy the base library if we don't have one yet
if [ ! -f "$OBJ_DIR/libwineserver.a" ]; then
    if [ -f "$APP_LIB" ]; then
        cp "$APP_LIB" "$OBJ_DIR/libwineserver.a"
    else
        echo "ERROR: No base libwineserver.a found"
        exit 1
    fi
fi

CC_FLAGS=(
    -arch arm64 -isysroot "$SDK" -miphoneos-version-min=17.0 -O2
    -I"$WINE_SRC/include" -I"$WINE_SRC/include/wine"
    -I"$WINE_SRC/build-macos/include"
    -I"$BUILD_DIR" -I"$WINE_SRC/server"
    -I"$SHIMS_DIR"
    -I"$BUILD_DIR/../madsync" -DHAVE_LINUX_NTSYNC_H=1
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
    # ml574: object.c must appear in BOTH lists — SOURCES compiles it,
    # REPLACEMENTS inserts it into the prebuilt base archive. An entry in
    # only the first compiles, prints OK, and is silently discarded.
    "object:$WINE_SRC/server/object.c:object.o"
    # ml805: event/handle carry the [evt-hist] instrumentation. Both MUST be
    # listed here -- they are otherwise linked from a prebuilt object and the
    # source edits would be dead code, the same trap as the unix/*.c forks.
    "event:$WINE_SRC/server/event.c:event.o"
    "handle:$WINE_SRC/server/handle.c:handle.o"
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
    # ml952 also puts the fastsync claim release in check_wait() here.
    "thread:$WINE_SRC/server/thread.c:thread.o"
    # ml1058: in-process synchronisation. The archive's copy was compiled with no
    # ntsync header, i.e. as the all-stubs variant; build the real one against the
    # userspace driver in build/madsync.
    "inproc_sync:$WINE_SRC/server/inproc_sync.c:inproc_sync.o"
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

case "${1:-all}" in
    all)
        echo "=== Building all patched wineserver files ==="
        for entry in "${PATCHED_FILES[@]}"; do
            IFS=: read -r name src old_obj <<< "$entry"
            # Support absolute paths (e.g. upstream files via $WINE_SRC)
            if [[ "$src" == /* ]]; then
                compile_one "$src" "$name"
            else
                compile_one "$BUILD_DIR/$src" "$name"
            fi
        done
        ;;
    request|main|mach|unicode)
        for entry in "${PATCHED_FILES[@]}"; do
            IFS=: read -r name src old_obj <<< "$entry"
            if [[ "$name" == "${1}_ios" || "$name" == "${1}" ]]; then
                compile_one "$BUILD_DIR/$src" "$name"
            fi
        done
        ;;
    *)
        echo "Usage: $0 [all|request|main|mach|unicode]"
        exit 1
        ;;
esac

echo ""
echo "=== Updating libwineserver.a ==="

# Map of patched .o files to the original .o names they replace
# Pairs of "new_obj_filename:old_obj_filename_in_archive". Plain array
# iteration to avoid bash assoc-array word-splitting issues seen in zsh-launched
# build environments.
REPLACEMENTS=(
    "wine_log_ios.o:wine_log_ios.o"
    "request_ios.o:request.o"
    "main_ios.o:main.o"
    "mach_ios.o:mach.o"
    "unicode_ios.o:unicode.o"
    "fd_ios.o:fd.o"
    "process_ios.o:process.o"
    "wineserver_ios_kill.o:wineserver_ios_kill.o"
    "window.o:window.o"
    "user.o:user.o"
    "class.o:class.o"
    "region.o:region.o"
    "queue.o:queue.o"
    "mapping.o:mapping.o"
    "winstation.o:winstation.o"
    "thread.o:thread.o"
    "event.o:event.o"
    "inproc_sync.o:inproc_sync.o"
    "sock.o:sock.o"
    "object.o:object.o"
    "async.o:async.o"
    # ml805: BOTH lists matter. PATCHED_FILES only compiles; REPLACEMENTS is what
    # actually swaps the object into the archive. Adding to one and not the other
    # compiles cleanly, ships the OLD object, and fails at link with an undefined
    # symbol -- which is exactly what happened first try.
    "event.o:event.o"
    "handle.o:handle.o"
    "inproc_sync.o:inproc_sync.o"   # ml1058
)

for entry in "${REPLACEMENTS[@]}"; do
    new_obj="${entry%%:*}"
    old_obj="${entry##*:}"
    if [ -f "$OBJ_DIR/$new_obj" ]; then
        ar d "$OBJ_DIR/libwineserver.a" "$old_obj" 2>/dev/null || true
        ar d "$OBJ_DIR/libwineserver.a" "$new_obj" 2>/dev/null || true
        ar r "$OBJ_DIR/libwineserver.a" "$OBJ_DIR/$new_obj"
    fi
done

echo ""
echo "=== Renaming colliding symbols in every .o (objcopy sweep) ==="
# Renames internal-to-archive: extract every .o, rename the 10 symbols
# we know collide with win32u-unix, repackage. Affects definitions AND
# references uniformly, so cross-file calls inside wineserver still
# resolve. Externals (win32u, etc.) only see the ws_-prefixed names.
OBJCOPY=$(command -v llvm-objcopy || echo /opt/homebrew/opt/llvm/bin/llvm-objcopy)
[ -x "$OBJCOPY" ] || OBJCOPY=/opt/homebrew/Cellar/llvm/22.1.0/bin/llvm-objcopy
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
(cd "$TMP_RENAME_DIR" && ar x "$OBJ_DIR/libwineserver.a")
for f in "$TMP_RENAME_DIR"/*.o; do
    "$OBJCOPY" "${RENAME_ARGS[@]}" "$f"
done
rm "$OBJ_DIR/libwineserver.a"
ar rcs "$OBJ_DIR/libwineserver.a" "$TMP_RENAME_DIR"/*.o
rm -rf "$TMP_RENAME_DIR"
echo "  symbol rename + repack OK"

echo "Copying to app..."
cp "$OBJ_DIR/libwineserver.a" "$APP_LIB"
echo "Done! libwineserver.a: $(wc -c < "$APP_LIB" | tr -d ' ') bytes"
