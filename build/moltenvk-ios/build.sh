#!/bin/bash
# GPL-3.0-or-later WITH the Madeira Converter Exception, version 1.
# Build MoltenVK (Vulkan on Metal) for iOS and stage it at
# app/Madeira/gl/libMoltenVK.dylib, the Vulkan implementation Mesa's Zink
# driver (build/mesa-ios/build.sh) loads for Madeira's desktop-OpenGL backend.
#
# Source: research/MoltenVK, `git clone -b v1.4.2 https://github.com/KhronosGroup/MoltenVK`.
# fetchDependencies downloads and builds SPIRV-Cross, SPIRV-Tools, cereal and the
# Vulkan headers into External/; the first run takes a while.
set -eu
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="${MOLTENVK_SRC:-$R/research/MoltenVK}"
OUT="$R/app/Madeira/gl"
LIC="$R/app/Madeira/licenses"

if [ ! -f "$SRC/fetchDependencies" ]; then
    echo "MoltenVK source not found at $SRC" >&2
    echo "  git clone -b v1.4.2 https://github.com/KhronosGroup/MoltenVK \"$SRC\"" >&2
    exit 1
fi

cd "$SRC"
[ -d External/build ] || ./fetchDependencies --ios
make ios

BIN="$SRC/Package/Release/MoltenVK/dynamic/MoltenVK.xcframework/ios-arm64/MoltenVK.framework/MoltenVK"
mkdir -p "$OUT" "$LIC"
cp "$BIN" "$OUT/libMoltenVK.dylib"
install_name_tool -id @rpath/libMoltenVK.dylib "$OUT/libMoltenVK.dylib"
git -C "$SRC" describe --tags --always > "$OUT/libMoltenVK.version"

cp "$SRC/LICENSE" "$LIC/MoltenVK-Apache-2.0.txt"
cp "$SRC/External/SPIRV-Cross/LICENSE" "$LIC/SPIRV-Cross-Apache-2.0.txt"
cp "$SRC/External/SPIRV-Tools/LICENSE" "$LIC/SPIRV-Tools-Apache-2.0.txt"
cp "$SRC/External/cereal/LICENSE" "$LIC/cereal-BSD-3-Clause.txt"
ls -l "$OUT/libMoltenVK.dylib"
