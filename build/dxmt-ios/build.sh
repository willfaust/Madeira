#!/bin/bash
# Build DXMT winemetal unix side + airconv + dxbc_parser as iOS-aarch64
# static library, for linking into Madeira.app.
#
# Produces: libdxmt_unix.a
set -eu

BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$BUILD_DIR/../.." && pwd)"
DXMT_SRC="$REPO_ROOT/research/dxmt/src"
DXMT_ROOT="$REPO_ROOT/research/dxmt"
LLVM_SRC="$REPO_ROOT/toolchains/llvm-project/llvm"
LLVM_BUILD="$REPO_ROOT/toolchains/llvm-ios-build"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
OBJ_DIR="$BUILD_DIR/obj"
OUT_LIB="$BUILD_DIR/libdxmt_unix.a"

mkdir -p "$OBJ_DIR"

COMMON_FLAGS="-arch arm64 -isysroot $SDK -miphoneos-version-min=18.0 -fblocks -O2"
INCLUDES="-I$DXMT_ROOT/include -I$DXMT_ROOT/libs -I$DXMT_SRC/winemetal -I$DXMT_SRC/airconv"
INCLUDES_DIRECTX="-I$DXMT_ROOT/include/native/directx -I$DXMT_ROOT/include/native/windows"
INCLUDES_SHADERS="-I$BUILD_DIR/shader-headers"
LLVM_INCLUDES="-I$LLVM_BUILD/include -I$LLVM_SRC/include"
AIRCONV_DEFS="-D_FILE_OFFSET_BITS=64 -D__STDC_CONSTANT_MACROS -D__STDC_FORMAT_MACROS -D__STDC_LIMIT_MACROS"
CXX_FLAGS="-std=c++20 -fno-exceptions -fno-rtti"

# MADEIRA (WOW64_DESIGN.md section 8, `dxmt_madeira_native`): the D3D9
# frontend and its DXMT substrate, compiled as NATIVE iOS-arm64 code into this
# same archive.  Nothing about that code needs to be x86 (section 8 premise),
# and natively the winemetal PE->unix boundary disappears: nativemetal's
# wineunixlib.h turns WINE_UNIX_CALL into a table-indirect call, which on this
# target is a plain function call into the objects built above instead of a
# JIT exit (section 8.2(a)).
#
# -I ordering matters: src/nativemetal must come BEFORE src/winemetal so that
# `#include <wineunixlib.h>` picks up the 13-line native one rather than the
# ntdll-private PE one.  The table it names is renamed on iOS
# (winemetal_unix.c:5084), so point it at the real symbol on the command line
# rather than editing either file.
MADEIRA_DEFS="-DDXMT_NATIVE=1 -DDXMT_MADEIRA=1 -DDXMT_IOS=1 -DDXMT_PAGE_SIZE=4096 -DNOMINMAX"
MADEIRA_INCLUDES="-I$DXMT_SRC/nativemetal -I$DXMT_ROOT/include -I$DXMT_ROOT/libs \
 -I$DXMT_SRC/winemetal -I$DXMT_SRC/airconv -I$DXMT_SRC/util -I$DXMT_SRC/dxmt \
 -I$DXMT_SRC/d3d9 -I$DXMT_SRC/d3d9/unix -I$DXMT_SRC/d3d9shim"
# The frontend throws (MTLD3DError) and the imported code uses dynamic_cast,
# so it needs the two flags the rest of this archive is built without.
MADEIRA_CXX_FLAGS="-std=c++20 -fexceptions -frtti"
# The same suppressions research/dxmt/meson.build:48-62 applies to every DXMT
# target; -Wno-extern-c-compat is the one that matters here (the imported
# d3d11.h declares `struct CD3D11_DEFAULT {}`, which is size 0 in C and 1 in
# C++).
MADEIRA_WARNINGS="-Wno-unused-parameter -Wno-missing-field-initializers \
 -Wno-missing-braces -Wno-extern-c-compat -Wno-unused-const-variable \
 -Wno-unused-private-field -Wno-microsoft-exception-spec"

SUCCEEDED=0
FAILED=0
FAILED_FILES=""

compile_objc() {
    local src=$1 name=$2
    # MADEIRA_ONLY=<name>: recompile one object only. madeira_ir_unix carries a __DATE__
    # stamp in the shader-cache key, so a full rebuild costs a full shader recompile on device.
    if [ -n "${MADEIRA_ONLY:-}" ] && [ "$name" != "$MADEIRA_ONLY" ]; then return 0; fi
    printf "  %-40s " "$name"
    if xcrun -sdk iphoneos clang $COMMON_FLAGS -x objective-c $INCLUDES \
        -c "$src" -o "$OBJ_DIR/$name.o" 2>"$OBJ_DIR/$name.err"; then
        echo "OK"; SUCCEEDED=$((SUCCEEDED+1))
    else
        echo "FAILED"; FAILED=$((FAILED+1)); FAILED_FILES="$FAILED_FILES $name"
    fi
}

compile_cxx() {
    local src=$1 name=$2 extra="${3:-}"
    # MADEIRA_ONLY=<name>: recompile one object only. madeira_ir_unix carries a __DATE__
    # stamp in the shader-cache key, so a full rebuild costs a full shader recompile on device.
    if [ -n "${MADEIRA_ONLY:-}" ] && [ "$name" != "$MADEIRA_ONLY" ]; then return 0; fi
    printf "  %-40s " "$name"
    if xcrun -sdk iphoneos clang++ $COMMON_FLAGS $CXX_FLAGS $INCLUDES $INCLUDES_DIRECTX $INCLUDES_SHADERS $LLVM_INCLUDES $AIRCONV_DEFS $extra \
        -c "$src" -o "$OBJ_DIR/$name.o" 2>"$OBJ_DIR/$name.err"; then
        echo "OK"; SUCCEEDED=$((SUCCEEDED+1))
    else
        echo "FAILED"; FAILED=$((FAILED+1)); FAILED_FILES="$FAILED_FILES $name"
    fi
}

# MADEIRA: the native D3D9 frontend and its substrate (section 8.10 step 1).
compile_madeira_cxx() {
    local src=$1 name=$2 extra="${3:-}"
    printf "  %-40s " "$name"
    if xcrun -sdk iphoneos clang++ $COMMON_FLAGS $MADEIRA_CXX_FLAGS $MADEIRA_WARNINGS \
        $MADEIRA_INCLUDES $INCLUDES_DIRECTX $INCLUDES_SHADERS $MADEIRA_DEFS $extra \
        -c "$src" -o "$OBJ_DIR/$name.o" 2>"$OBJ_DIR/$name.err"; then
        echo "OK"; SUCCEEDED=$((SUCCEEDED+1))
    else
        echo "FAILED"; FAILED=$((FAILED+1)); FAILED_FILES="$FAILED_FILES $name"
    fi
}

compile_madeira_c() {
    local src=$1 name=$2 extra="${3:-}"
    printf "  %-40s " "$name"
    if xcrun -sdk iphoneos clang $COMMON_FLAGS -std=c11 $MADEIRA_WARNINGS \
        $MADEIRA_INCLUDES $INCLUDES_DIRECTX $INCLUDES_SHADERS $MADEIRA_DEFS $extra \
        -c "$src" -o "$OBJ_DIR/$name.o" 2>"$OBJ_DIR/$name.err"; then
        echo "OK"; SUCCEEDED=$((SUCCEEDED+1))
    else
        echo "FAILED"; FAILED=$((FAILED+1)); FAILED_FILES="$FAILED_FILES $name"
    fi
}

# ---- madeira-d3d12 M1 canary (optional) -------------------------------------
# Compiled into this library so the app can run the shader-converter gate
# in-process. Guarded: the converter package is a locally supplied dependency
# and the DXMT build must not start failing when it is absent.
compile_objcxx_arc() {
    local src=$1 name=$2 extra="${3:-}"
    # MADEIRA_ONLY=<name>: recompile one object only. madeira_ir_unix carries a __DATE__
    # stamp in the shader-cache key, so a full rebuild costs a full shader recompile on device.
    if [ -n "${MADEIRA_ONLY:-}" ] && [ "$name" != "$MADEIRA_ONLY" ]; then return 0; fi
    printf "  %-40s " "$name"
    if xcrun -sdk iphoneos clang++ $COMMON_FLAGS -std=c++20 -fobjc-arc -x objective-c++ $extra \
        -c "$src" -o "$OBJ_DIR/$name.o" 2>"$OBJ_DIR/$name.err"; then
        echo "OK"; SUCCEEDED=$((SUCCEEDED+1))
    else
        echo "FAILED"; FAILED=$((FAILED+1)); FAILED_FILES="$FAILED_FILES $name"
    fi
}
if [[ -f "$BUILD_DIR/../madeira-d3d12/deps.sh" ]] && \
   source "$BUILD_DIR/../madeira-d3d12/deps.sh" 2>/dev/null; then
    echo "=== madeira-d3d12 canary (Objective-C++, Metal Shader Converter) ==="
    compile_objcxx_arc "$REPO_ROOT/research/madeira-d3d12/tests/native/msc_canary.mm" \
                       msc_canary "-DIR_PRIVATE_IMPLEMENTATION -I$MSC_INCLUDE"
    # The runtime conversion service reached from the D3D12 runtime through
    # winemetal's unix call. Deliberately NOT defining IR_PRIVATE_IMPLEMENTATION
    # here: the converter's runtime header emits its bind points and helper
    # bodies only where that macro is set, and defining it in a second
    # translation unit gives duplicate symbols. The canary owns the one copy.
    # ml1008: also needs airconv_public.h -- shader-model-5.x DXBC goes to the
    # in-tree AIR compiler, which is linked into this same archive, so the shim
    # includes the compiler's real header rather than restating its structs.
    compile_objcxx_arc "$REPO_ROOT/research/madeira-d3d12/src/unix/madeira_ir_unix.mm" \
                       madeira_ir_unix "-I$MSC_INCLUDE -I$REPO_ROOT/research/madeira-d3d12/src $INCLUDES $INCLUDES_DIRECTX"
    # ml1011: the input-layout resolver, plain C++ because DXBCParser's signature
    # reader includes a Windows shim whose BOOL clashes with Objective-C's.
    compile_cxx "$REPO_ROOT/research/madeira-d3d12/src/unix/madeira_sm5_ia.cpp" \
                madeira_sm5_ia "-I$REPO_ROOT/research/madeira-d3d12/src"
    # ml1149: AMD AGS 64-bit atomics -> native SM6.6 atomics, a DXIL rewrite on
    # the LLVM 15 that airconv already links (bitcode reader + writer).
    compile_cxx "$REPO_ROOT/research/madeira-d3d12/src/unix/madeira_ags.cpp" madeira_ags
else
    echo "=== madeira-d3d12 canary SKIPPED (converter package not resolvable) ==="
fi

echo "=== winemetal unix (Objective-C) ==="
compile_objc "$DXMT_SRC/winemetal/unix/winemetal_unix.c" winemetal_unix
compile_objc "$DXMT_SRC/winemetal/unix/cache.c"          cache

echo "=== airconv (C++ 20, needs LLVM headers) ==="
for cpp in airconv_context.cpp air_type.cpp air_signature.cpp air_operations.cpp \
           dxbc_converter.cpp dxbc_converter_gs.cpp dxbc_converter_ts.cpp \
           dxbc_converter_basicblock.cpp dxbc_converter_cfg.cpp \
           dxbc_instructions.cpp dxbc_signature.cpp metallib_writer.cpp \
           dxso_compile.cpp ffp_compile.cpp; do
    name=$(basename "$cpp" .cpp)
    compile_cxx "$DXMT_SRC/airconv/$cpp" "$name"
done
compile_cxx "$DXMT_SRC/airconv/nt/air_builder.cpp" air_builder
compile_cxx "$DXMT_SRC/airconv/nt/dxbc_converter_base.cpp" dxbc_converter_base
compile_cxx "$DXMT_SRC/airconv/transforms/lower_16bit_texread.cpp" lower_16bit_texread

echo "=== DXBCParser (uses exceptions — override) ==="
for cpp in BlobContainer.cpp DXBCUtils.cpp ShaderBinary.cpp; do
    name=dxbc_$(basename "$cpp" .cpp)
    # ShaderBinary uses `throw`, so we can't use -fno-exceptions from CXX_FLAGS.
    printf "  %-40s " "$name"
    if xcrun -sdk iphoneos clang++ $COMMON_FLAGS -std=c++20 -fno-rtti \
            $INCLUDES $INCLUDES_DIRECTX $AIRCONV_DEFS \
            -c "$DXMT_ROOT/libs/DXBCParser/$cpp" -o "$OBJ_DIR/$name.o" 2>"$OBJ_DIR/$name.err"; then
        echo "OK"; SUCCEEDED=$((SUCCEEDED+1))
    else
        echo "FAILED"; FAILED=$((FAILED+1)); FAILED_FILES="$FAILED_FILES $name"
    fi
done

echo "=== MADEIRA: dxmt_madeira_native -- generated headers ==="
# meson produces version.h with vcs_tag (meson.build:176-180); dxmt_info.cpp
# is the only consumer.  Same content, same `git describe --always`.
mkdir -p "$BUILD_DIR/shader-headers"
sed "s/@VCS_TAG@/$(git -C "$DXMT_ROOT" describe --always 2>/dev/null || echo unknown)/" \
    "$DXMT_ROOT/version.h.in" > "$BUILD_DIR/shader-headers/version.h"
echo "  version.h                                OK"

echo "=== MADEIRA: dxmt_madeira_native -- internal command library ==="
# dxmt_command.cpp embeds the compiled metallib as a C array; meson does this
# with the metalir/metallib/xxd generator chain (src/dxmt/meson.build:24-32).
# Same chain, same symbol names (xxd -n dxmt_command gives dxmt_command /
# dxmt_command_len, which is what dxmt_command.cpp:16 expects).
if [ ! -f "$BUILD_DIR/shader-headers/dxmt_command.h" ] \
   || [ "$DXMT_SRC/dxmt/dxmt_command.metal" -nt "$BUILD_DIR/shader-headers/dxmt_command.h" ]; then
    mkdir -p "$BUILD_DIR/shader-headers"
    (cd "$BUILD_DIR/shader-headers" \
     && xcrun -sdk macosx metal -o dxmt_command.air -c "$DXMT_SRC/dxmt/dxmt_command.metal" \
     && xcrun -sdk macosx metallib -o dxmt_command.metallib dxmt_command.air \
     && xxd -n dxmt_command -i dxmt_command.metallib dxmt_command.h)
    echo "  dxmt_command.h                           OK"
else
    echo "  dxmt_command.h                           CACHED"
fi

echo "=== MADEIRA: dxmt_madeira_native -- util ==="
# MADEIRA (WOW64_DESIGN.md, ml1070): util_futex.cpp carries dxmt::futex's
# backend selection and the one line that names it.  On this (Darwin) target
# it selects std::atomic wait/notify, which is already __ulock_wait -- but the
# selection is a runtime branch so that both halves compile the same code, and
# a runtime branch still needs the object.
for cpp in util_env.cpp util_string.cpp util_bloom.cpp util_futex.cpp thread.cpp \
           com/com_guid.cpp com/com_private_data.cpp config/config.cpp log/log.cpp \
           sha1/sha1_util.cpp \
           wsi_monitor_headless.cpp wsi_window_madeira.cpp wsi_platform_madeira.cpp; do
    name=$(basename "$cpp" .cpp)
    compile_madeira_cxx "$DXMT_SRC/util/$cpp" "$name"
done
compile_madeira_c "$DXMT_SRC/util/sha1/sha1.c" sha1

echo "=== MADEIRA: dxmt_madeira_native -- winemetal thunks (now direct calls) ==="
# The PE-side thunk bodies, compiled natively: WINE_UNIX_CALL resolves through
# nativemetal/wineunixlib.h to the table winemetal_unix.c already defines in
# this archive.  airconv_thunks.c is deliberately NOT built -- its SM50*/DXSO*
# bodies are thunks for the same functions airconv_context.cpp and
# dxso_compile.cpp define natively above, so building both would be a
# duplicate-symbol error and the native definitions are the real ones.
compile_madeira_c "$DXMT_SRC/winemetal/winemetal_thunks.c" winemetal_thunks \
    "-D__wine_unix_call_funcs=dxmt_winemetal_unix_call_funcs"
compile_madeira_c "$DXMT_SRC/winemetal/wmt_api_census.c" wmt_api_census

echo "=== MADEIRA: dxmt_madeira_native -- dxmt ==="
for cpp in dxmt_format.cpp dxmt_names.cpp dxmt_command_queue.cpp dxmt_command.cpp \
           dxmt_capture.cpp dxmt_info.cpp dxmt_device.cpp dxmt_buffer.cpp \
           dxmt_texture.cpp dxmt_context.cpp dxmt_dynamic.cpp dxmt_staging.cpp \
           dxmt_hud_state.cpp dxmt_allocation.cpp dxmt_presenter.cpp dxmt_sampler.cpp \
           dxmt_resource_initializer.cpp dxmt_mem_census.cpp dxmt_bcn.cpp \
           dxmt_shader_cache.cpp; do
    name=$(basename "$cpp" .cpp)
    compile_madeira_cxx "$DXMT_SRC/dxmt/$cpp" "$name"
done

echo "=== MADEIRA: dxmt_madeira_native -- d3d9 frontend ==="
for cpp in d3d9.cpp d3d9_buffer.cpp d3d9_census.cpp d3d9_clear_quad.cpp \
           d3d9_cube_texture.cpp d3d9_device.cpp d3d9_format.cpp d3d9_fvf.cpp \
           d3d9_interface.cpp d3d9_mem.cpp d3d9_query.cpp d3d9_shader.cpp \
           d3d9_shader_scan.cpp d3d9_state_block.cpp d3d9_state_defaults.cpp \
           d3d9_surface.cpp d3d9_swapchain.cpp d3d9_texture.cpp d3d9_validation.cpp \
           d3d9_vertex_declaration.cpp d3d9_volume.cpp d3d9_volume_texture.cpp; do
    name=$(basename "$cpp" .cpp)
    compile_madeira_cxx "$DXMT_SRC/d3d9/$cpp" "$name"
done

echo "=== MADEIRA: dxmt_madeira_native -- d3d9 unix boundary ==="
# d3d9_unix.c and d3d9_unix_table.c are GENERATED by
# src/d3d9shim/gen_d3d9_thunks.py -- regenerate, do not edit.
compile_madeira_c "$DXMT_SRC/d3d9/unix/d3d9_unix.c" d3d9_unix
compile_madeira_c "$DXMT_SRC/d3d9/unix/d3d9_unix_table.c" d3d9_unix_table
compile_madeira_cxx "$DXMT_SRC/d3d9/unix/d3d9_native_glue.cpp" d3d9_native_glue

echo ""
echo "Results: $SUCCEEDED succeeded, $FAILED failed"
if [ -n "$FAILED_FILES" ]; then
    echo "Failed:$FAILED_FILES"
    echo "See .err files in $OBJ_DIR/"
    exit 1
fi

echo ""
echo "=== Archiving libdxmt_unix.a ==="
xcrun -sdk iphoneos ar rcs "$OUT_LIB" "$OBJ_DIR"/*.o
echo "Built: $OUT_LIB ($(wc -c < "$OUT_LIB" | tr -d ' ') bytes)"

# The app links libdxmt_combined.a (this unix side merged with the LLVM archives
# airconv needs), NOT libdxmt_unix.a. Refreshing only the latter is how a change
# here reaches nothing: the app would keep linking the previous objects and the
# build would look clean. Replace our members in place and re-index.
COMBINED="$BUILD_DIR/libdxmt_combined.a"
if [ -f "$COMBINED" ]; then
    echo "=== Refreshing libdxmt_combined.a ==="
    xcrun -sdk iphoneos ar r "$COMBINED" "$OBJ_DIR"/*.o
    xcrun -sdk iphoneos ranlib "$COMBINED"
    echo "Refreshed: $COMBINED ($(wc -c < "$COMBINED" | tr -d ' ') bytes)"
    APP_COPY="$REPO_ROOT/app/Madeira/libdxmt_combined.a"
    if [ -f "$APP_COPY" ]; then cp "$COMBINED" "$APP_COPY"; echo "Staged: $APP_COPY"; fi
else
    echo "NOTE: $COMBINED absent; the app links that file, so build it before deploying."
fi
