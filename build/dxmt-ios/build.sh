#!/bin/bash
# Build DXMT's iOS Metal bridge and shader translator, then combine LLVM.
set -euo pipefail

BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$BUILD_DIR/../.." && pwd)"
DXMT_ROOT="$REPO_ROOT/research/dxmt"
DXMT_SRC="$DXMT_ROOT/src"
LLVM_SRC="$REPO_ROOT/toolchains/llvm-project/llvm"
LLVM_BUILD="$REPO_ROOT/toolchains/llvm-ios-build"
IOS_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET:-18.0}"
command -v xcrun >/dev/null || { echo "ERROR: DXMT iOS builds require macOS with Xcode (xcrun not found)." >&2; exit 1; }
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
OBJ_DIR="$BUILD_DIR/obj"
SHADER_DIR="$BUILD_DIR/shader-headers"

for header in "$LLVM_SRC/include/llvm/IR/Module.h" \
              "$LLVM_BUILD/include/llvm/Config/llvm-config.h" \
              "$DXMT_ROOT/include/native/directx/d3d11.h"; do
    test -s "$header" || { echo "Missing $header; run build-llvm.sh and initialize DXMT submodules." >&2; exit 1; }
done
for component in Core Passes BitWriter; do
    python3 "$REPO_ROOT/tools/validate-ios-bundle.py" --archive "$LLVM_BUILD/lib/libLLVM$component.a"
done
mkdir -p "$OBJ_DIR" "$SHADER_DIR"

# Required by airconv_context.cpp, but absent from clean checkouts. Preserve
# the fork's AIR target: its generated modules currently use the same triple.
# Runtime conversion to an iOS AIR target requires separate device validation.
for shader in air_msad air_samplepos air_tessellation; do
    xcrun --sdk macosx metal -std=metal3.1 --target=air64-apple-macos14.0 \
        -c "$DXMT_SRC/airconv/shaders/$shader.metal" -o "$SHADER_DIR/$shader.air"
    xxd -n "$shader" -i "$SHADER_DIR/$shader.air" "$SHADER_DIR/$shader.h"
done

# Arrays preserve repository and SDK paths containing spaces.
COMMON_FLAGS=(-arch arm64 -isysroot "$SDK" "-miphoneos-version-min=$IOS_DEPLOYMENT_TARGET" -fblocks -O2)
INCLUDES=(-I"$DXMT_ROOT/include" -I"$DXMT_ROOT/libs" -I"$DXMT_SRC/winemetal" -I"$DXMT_SRC/airconv")
DIRECTX_INCLUDES=(-I"$DXMT_ROOT/include/native/directx" -I"$DXMT_ROOT/include/native/windows")
LLVM_INCLUDES=(-I"$LLVM_BUILD/include" -I"$LLVM_SRC/include")
AIRCONV_DEFS=(-D_FILE_OFFSET_BITS=64 -D__STDC_CONSTANT_MACROS -D__STDC_FORMAT_MACROS -D__STDC_LIMIT_MACROS)
OBJECTS=()

compile() {
    local name=$1 compiler=$2 source=$3
    shift 3
    echo "Compiling $name"
    if ! xcrun --sdk iphoneos "$compiler" "${COMMON_FLAGS[@]}" "${INCLUDES[@]}" "$@" \
        -c "$source" -o "$OBJ_DIR/$name.o" >"$OBJ_DIR/$name.log" 2>&1; then
        cat "$OBJ_DIR/$name.log" >&2
        return 1
    fi
    OBJECTS+=("$OBJ_DIR/$name.o")
}

compile winemetal_unix clang "$DXMT_SRC/winemetal/unix/winemetal_unix.c" -x objective-c
compile cache clang "$DXMT_SRC/winemetal/unix/cache.c" -x objective-c

for cpp in airconv_context.cpp air_type.cpp air_signature.cpp air_operations.cpp \
           dxbc_converter.cpp dxbc_converter_gs.cpp dxbc_converter_ts.cpp \
           dxbc_converter_basicblock.cpp dxbc_converter_cfg.cpp \
           dxbc_instructions.cpp dxbc_signature.cpp metallib_writer.cpp \
           nt/air_builder.cpp nt/dxbc_converter_base.cpp transforms/lower_16bit_texread.cpp; do
    compile "$(basename "$cpp" .cpp)" clang++ "$DXMT_SRC/airconv/$cpp" \
        -std=c++20 -fno-exceptions -fno-rtti -funwind-tables \
        "${DIRECTX_INCLUDES[@]}" "${LLVM_INCLUDES[@]}" "${AIRCONV_DEFS[@]}" -I"$SHADER_DIR"
done

# ShaderBinary uses C++ exceptions, unlike airconv and LLVM.
for cpp in BlobContainer.cpp DXBCUtils.cpp ShaderBinary.cpp; do
    compile "dxbc_$(basename "$cpp" .cpp)" clang++ "$DXMT_ROOT/libs/DXBCParser/$cpp" \
        -std=c++20 -fno-rtti "${DIRECTX_INCLUDES[@]}" "${AIRCONV_DEFS[@]}"
done

# Use only this invocation's objects, so stale objects cannot enter the app.
xcrun --sdk iphoneos libtool -static -o "$BUILD_DIR/libdxmt_unix.new.a" "${OBJECTS[@]}"
python3 "$REPO_ROOT/tools/validate-ios-bundle.py" --archive "$BUILD_DIR/libdxmt_unix.new.a"
mv "$BUILD_DIR/libdxmt_unix.new.a" "$BUILD_DIR/libdxmt_unix.a"
LLVM_ARCHIVES=("$LLVM_BUILD"/lib/libLLVM*.a)
for archive in "${LLVM_ARCHIVES[@]}"; do
    python3 "$REPO_ROOT/tools/validate-ios-bundle.py" --archive "$archive"
done
xcrun --sdk iphoneos libtool -static -o "$BUILD_DIR/libdxmt_combined.new.a" \
    "$BUILD_DIR/libdxmt_unix.a" "${LLVM_ARCHIVES[@]}"
python3 "$REPO_ROOT/tools/validate-ios-bundle.py" --archive "$BUILD_DIR/libdxmt_combined.new.a"
mv "$BUILD_DIR/libdxmt_combined.new.a" "$BUILD_DIR/libdxmt_combined.a"
mkdir -p "$REPO_ROOT/app/Madeira"
cp "$BUILD_DIR/libdxmt_combined.a" "$REPO_ROOT/app/Madeira/"
echo "Built: $BUILD_DIR/libdxmt_combined.a"
