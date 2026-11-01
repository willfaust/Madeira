#!/bin/bash
# GPL-3.0-or-later WITH the Madeira Converter Exception, version 1.
# Build MoltenVK (Vulkan on Metal) for iOS and stage it at
# app/Madeira/gl/libMoltenVK.dylib, the Vulkan implementation Mesa's Zink
# driver (build/mesa-ios/build.sh) loads for Madeira's desktop-OpenGL backend.
#
# Source: research/MoltenVK, `git clone -b v1.4.2 https://github.com/KhronosGroup/MoltenVK`.
# fetchDependencies downloads and builds SPIRV-Cross, SPIRV-Tools, cereal and the
# Vulkan headers into External/; the first run takes a while.
# build/moltenvk-ios/patches/*.patch are applied to the checkout first (see the
# README there); they change MoltenVK and are offered under its licence (Apache-2.0).
set -eu
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HERE="$R/build/moltenvk-ios"
SRC="${MOLTENVK_SRC:-$R/research/MoltenVK}"
OUT="$R/app/Madeira/gl"
LIC="$R/app/Madeira/licenses"

if [ ! -f "$SRC/fetchDependencies" ]; then
    echo "MoltenVK source not found at $SRC" >&2
    echo "  git clone -b v1.4.2 https://github.com/KhronosGroup/MoltenVK \"$SRC\"" >&2
    exit 1
fi

# Each patch once: one whose reverse applies is already in the checkout.
for p in "$HERE"/patches/[0-9]*.patch; do
    [ -e "$p" ] || continue
    if git -C "$SRC" apply --reverse --check "$p" 2>/dev/null; then
        echo "MoltenVK: $(basename "$p") already applied"
    else
        git -C "$SRC" apply "$p"
        echo "MoltenVK: applied $(basename "$p")"
    fi
done

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
