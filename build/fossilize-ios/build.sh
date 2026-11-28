#!/bin/bash
# Fossilize (Valve, MIT) for iOS, staged in app/Madeira/gl/:
#   libVkLayer_fossilize.dylib  the capture layer (VK_LAYER_fossilize), loaded through the Khronos
#                               loader (build/vulkan-loader-ios) when madeira.cfg fossilize = record|on;
#                               manifest gl/vulkan/explicit_layer.d/VkLayer_fossilize.json
#   libfossilize_replay.dylib   the replayer as a library (fossilize_replay_main), run in-process
#                               before the game starts when fossilize = replay|on (iOS apps can't
#                               spawn fossilize-replay processes)
# Source: ValveSoftware/Fossilize at REV with patches/*.patch (FOSSILIZE_VULKAN_LIBRARY, the
# library entry point). Needs: git, cmake, ninja, Xcode (iphoneos SDK).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
WORK="${WORK:-$HERE/work}"
REV=556da9ff7d7616704dda515756219ab1dab693ec
GL="$REPO_ROOT/app/Madeira/gl"
mkdir -p "$WORK"
if [ ! -d "$WORK/src/.git" ]; then
    git clone https://github.com/ValveSoftware/Fossilize.git "$WORK/src"
    git -C "$WORK/src" checkout -q "$REV"
    git -C "$WORK/src" submodule update --init --depth 1
    git -C "$WORK/src" -c user.name=madeira -c user.email=madeira@localhost am "$HERE"/patches/*.patch
fi
cmake -S "$WORK/src" -B "$WORK/build-ios" -G Ninja \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DFOSSILIZE_REPLAY_LIBRARY=ON -DFOSSILIZE_REPLAYER_SPIRV_VAL=OFF -DFOSSILIZE_TESTS=OFF
ninja -C "$WORK/build-ios" VkLayer_fossilize fossilize-replay-lib
mkdir -p "$GL/vulkan/explicit_layer.d"
for lib in layer/libVkLayer_fossilize.dylib cli/libfossilize_replay.dylib; do
    name="$(basename "$lib")"
    cp "$WORK/build-ios/$lib" "$GL/$name"
    install_name_tool -id "@rpath/$name" "$GL/$name"
    strip -x "$GL/$name"
    echo "  $GL/$name: $(wc -c < "$GL/$name" | tr -d ' ') bytes, sha256 $(shasum -a 256 "$GL/$name" | cut -c1-16)"
done
git -C "$WORK/src" rev-parse --short HEAD > "$GL/libfossilize.version"
