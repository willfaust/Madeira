#!/bin/bash
# Build matching 64-bit Wine Vulkan PE modules; never use an old DLL checkpoint.
set -euo pipefail
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TC="$R/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin"
export PATH="$TC:$PATH"
B="$R/wine/build-arm64ec"
[[ -f "$B/config.status" ]] || { echo "Configure the ARM64EC Wine tree first (docs/BUILDING.md)" >&2; exit 1; }
make -C "$B" dlls/winevulkan/arm64ec-windows/winevulkan.dll \
    dlls/vulkan-1/arm64ec-windows/vulkan-1.dll
for dll in winevulkan vulkan-1; do
    cp "$B/dlls/$dll/arm64ec-windows/$dll.dll" "$R/app/Madeira/arm64ec-windows/$dll.dll"
done
