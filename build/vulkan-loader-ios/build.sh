#!/bin/bash
# The Khronos Vulkan loader for iOS, staged as app/Madeira/gl/libvulkan.1.dylib. Used only when
# madeira.cfg fossilize = record|on: Madeira then points MADEIRA_VULKAN_LIBRARY at the loader, the
# loader loads the driver from gl/vulkan/icd.d/<driver>_icd.json (VK_DRIVER_FILES) and the capture
# layer from gl/vulkan/explicit_layer.d (VK_ADD_LAYER_PATH, VK_INSTANCE_LAYERS=VK_LAYER_fossilize).
# Without fossilize, Wine loads the driver directly as before. Apache-2.0.
# Needs: git, cmake, ninja, python3, Xcode (iphoneos SDK).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
WORK="${WORK:-$HERE/work}"
TAG=v1.4.368
GL="$REPO_ROOT/app/Madeira/gl"
mkdir -p "$WORK"
[ -d "$WORK/Vulkan-Headers" ] || git clone --depth 1 --branch "$TAG" https://github.com/KhronosGroup/Vulkan-Headers.git "$WORK/Vulkan-Headers"
[ -d "$WORK/Vulkan-Loader" ] || git clone --depth 1 --branch "$TAG" https://github.com/KhronosGroup/Vulkan-Loader.git "$WORK/Vulkan-Loader"
cmake -S "$WORK/Vulkan-Headers" -B "$WORK/build-headers" -G Ninja -DCMAKE_INSTALL_PREFIX="$WORK/headers-install"
cmake --install "$WORK/build-headers"
cmake -S "$WORK/Vulkan-Loader" -B "$WORK/build-ios" -G Ninja \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 \
    -DCMAKE_BUILD_TYPE=Release -DVULKAN_HEADERS_INSTALL_DIR="$WORK/headers-install" \
    -DCMAKE_PREFIX_PATH="$WORK/headers-install" -DBUILD_TESTS=OFF
ninja -C "$WORK/build-ios" vulkan
built="$(find "$WORK/build-ios/loader" -maxdepth 1 -name 'libvulkan.1*.dylib' -type f | head -1)"
cp "$built" "$GL/libvulkan.1.dylib"
install_name_tool -id "@rpath/libvulkan.1.dylib" "$GL/libvulkan.1.dylib"
strip -x "$GL/libvulkan.1.dylib"
echo "$TAG" > "$GL/libvulkan.version"
echo "  $GL/libvulkan.1.dylib: $(wc -c < "$GL/libvulkan.1.dylib" | tr -d ' ') bytes, sha256 $(shasum -a 256 "$GL/libvulkan.1.dylib" | cut -c1-16)"
