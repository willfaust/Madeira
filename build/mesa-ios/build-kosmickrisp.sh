#!/bin/bash
# GPL-3.0-or-later WITH the Madeira Converter Exception, version 1.
# Build Mesa's KosmicKrisp Vulkan driver (Vulkan 1.4 on Metal 4, src/kosmickrisp)
# for iOS arm64 -> libvulkan_kosmickrisp.dylib. See docs/KOSMICKRISP.md.
#
# Two steps, because KosmicKrisp (like every Mesa driver with OpenCL C helper
# kernels) needs three compilers that run on the BUILD machine:
#   mesa_clc      OpenCL C -> SPIR-V (clang + SPIRV-LLVM-Translator + SPIRV-Tools)
#   vtn_bindgen2  SPIR-V -> C bindings for the kernels
#   kk_clc        SPIR-V -> precompiled MSL for KosmicKrisp's internal kernels
# Step 1 builds them natively (Linux or macOS), step 2 cross-compiles the
# driver with -Dmesa-clc=system -Dprecomp-compiler=system.
#
# Source: Mesa 26.2.4 (https://archive.mesa3d.org/mesa-26.2.4.tar.xz, sha256
# bce5f7fbebb934373b86c999a064d52fb5065878dc57f287f95346648ec832e9), with
# build/mesa-ios/patches/kosmickrisp-ios-*.patch applied (MIT, like Mesa).
#
# Build-machine needs: meson >= 1.9.1, ninja, python3 with mako/pyyaml/packaging,
# LLVM 21 with clang development files (libclang-cpp + headers + the clang
# resource dir with opencl-c.h), SPIRV-LLVM-Translator 21 and SPIRV-Tools as
# pkg-config packages LLVMSPIRVLib and SPIRV-Tools. Point KK_LLVM_CONFIG at
# llvm-config and KK_HOST_PKG_CONFIG_PATH at the .pc files if they are not the
# system ones. iOS side: the iPhoneOS 26.x SDK (Metal 4 headers) through xcrun.
set -eu
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HERE="$R/build/mesa-ios"
WORK="${KK_WORK:-$HOME/.cache/mesa-kk}"
SRC="${KK_MESA_SRC:-$WORK/mesa-26.2.4}"
NATIVE="$WORK/build-native"
TOOLS="$WORK/host-tools"
B="$WORK/build-ios"
OUT="${KK_OUT:-$WORK/out}"
LLVM_CONFIG="${KK_LLVM_CONFIG:-llvm-config}"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"

if [ ! -f "$SRC/src/kosmickrisp/meson.build" ]; then
    echo "Mesa >= 25.3 source not found at $SRC" >&2
    echo "  curl -LO https://archive.mesa3d.org/mesa-26.2.4.tar.xz && tar -xf mesa-26.2.4.tar.xz -C \"$WORK\"" >&2
    exit 1
fi

if [ "${KK_PROFILE:-madeira}" = playport ]; then
    set -- "$HERE"/playport-patches/*.patch
else
    set -- "$HERE"/patches/kosmickrisp-ios-*.patch
fi
for p in "$@"; do
    [ -e "$p" ] || continue
    m="$SRC/.madeira-applied-$(basename "$p")"
    if [ ! -f "$m" ]; then
        patch -d "$SRC" -p1 --forward < "$p"
        touch "$m"
    fi
done

# Step 1: build-machine compilers.
if [ ! -x "$TOOLS/bin/kk_clc" ]; then
    mkdir -p "$WORK"
    printf "[binaries]\nllvm-config = '%s'\n" "$(command -v "$LLVM_CONFIG")" > "$WORK/native-llvm.ini.new"
    if cmp -s "$WORK/native-llvm.ini.new" "$WORK/native-llvm.ini"; then rm "$WORK/native-llvm.ini.new"
    else mv "$WORK/native-llvm.ini.new" "$WORK/native-llvm.ini"; fi
    if [ ! -f "$NATIVE/build.ninja" ]; then
        PKG_CONFIG_PATH="${KK_HOST_PKG_CONFIG_PATH:-${PKG_CONFIG_PATH:-}}" \
        meson setup "$NATIVE" "$SRC" --native-file "$WORK/native-llvm.ini" \
            --buildtype=release --prefix="$TOOLS" \
            -Dplatforms= -Dgallium-drivers= -Dvulkan-drivers=kosmickrisp \
            -Dopengl=false -Dgles1=disabled -Dgles2=disabled -Dglx=disabled -Degl=disabled -Dgbm=disabled \
            -Dllvm=enabled -Dshared-llvm=enabled \
            -Dmesa-clc=enabled -Dprecomp-compiler=enabled \
            -Dinstall-mesa-clc=true -Dinstall-precomp-compiler=true -Dmesa-clc-bundle-headers=enabled \
            -Dzstd=disabled -Dxmlconfig=disabled -Dexpat=disabled -Dvalgrind=disabled \
            -Dlibunwind=disabled -Dlmsensors=disabled -Dbuild-tests=false -Dvideo-codecs=
    fi
    ninja -C "$NATIVE" src/compiler/clc/mesa_clc src/compiler/spirv/vtn_bindgen2 src/kosmickrisp/clc/kk_clc
    mkdir -p "$TOOLS/bin"
    cp "$NATIVE/src/compiler/clc/mesa_clc" "$NATIVE/src/compiler/spirv/vtn_bindgen2" \
       "$NATIVE/src/kosmickrisp/clc/kk_clc" "$TOOLS/bin/"
fi

# Step 2: the driver for iOS.
mkdir -p "$B"
# Machine files are replaced only when they change, so ninja does not reconfigure.
sed "s|@SDK@|$SDK|g" "$HERE/kosmickrisp-ios-arm64.cross" > "$B/ios-arm64.cross.new"
printf "[binaries]\nmesa_clc = '%s'\nvtn_bindgen2 = '%s'\nkk_clc = '%s'\n" \
    "$TOOLS/bin/mesa_clc" "$TOOLS/bin/vtn_bindgen2" "$TOOLS/bin/kk_clc" > "$B/native-tools.ini.new"
for f in ios-arm64.cross native-tools.ini; do
    if cmp -s "$B/$f.new" "$B/$f"; then rm "$B/$f.new"; else mv "$B/$f.new" "$B/$f"; fi
done

if [ ! -f "$B/build.ninja" ]; then
    meson setup "$B" "$SRC" --cross-file "$B/ios-arm64.cross" --native-file "$B/native-tools.ini" \
        --buildtype=release -Db_ndebug=true --default-library=shared \
        -Dplatforms=macos \
        -Dvulkan-drivers=kosmickrisp -Dgallium-drivers= \
        -Dopengl=false -Dgles1=disabled -Dgles2=disabled \
        -Dglx=disabled -Degl=disabled -Dgbm=disabled \
        -Dllvm=disabled -Dmesa-clc=system -Dprecomp-compiler=system \
        -Dshader-cache="${KK_SHADER_CACHE:-disabled}" -Dxmlconfig=disabled \
        -Dzstd=disabled -Dlibunwind=disabled -Dvalgrind=disabled -Dlmsensors=disabled \
        -Dexpat=disabled -Dbuild-tests=false -Dvideo-codecs= \
        -Dvulkan-icd-dir=share/vulkan/icd.d
fi
ninja -C "$B" src/kosmickrisp/vulkan/libvulkan_kosmickrisp.dylib

mkdir -p "$OUT"
cp "$B/src/kosmickrisp/vulkan/libvulkan_kosmickrisp.dylib" "$OUT/libvulkan_kosmickrisp.dylib"
install_name_tool -id @rpath/libvulkan_kosmickrisp.dylib "$OUT/libvulkan_kosmickrisp.dylib"
xcrun -sdk iphoneos strip -x "$OUT/libvulkan_kosmickrisp.dylib"
echo "$(basename "$SRC")" > "$OUT/libvulkan_kosmickrisp.version"
ls -l "$OUT"
