#!/bin/bash
# Native DXC for x64 games: dxcompiler.dll 1.8.2407 built as ARM64EC.
#
# Games that compile HLSL at run time ship Microsoft's x64 dxcompiler.dll and
# run the whole compiler under FEX; every allocation it makes through
# CoTaskMemAlloc is an x64 -> native crossing (Path of Exile 2, which ships
# 1.8.2407.7, made 0.5-1.2 million a second while it compiled). This builds the
# same DXC release as ARM64EC, so the compiler runs natively and the game calls
# it through the same two exports (DxcCreateInstance, DxcCreateInstance2).
#
# The output goes into the bundle's arm64ec-windows directory (linked into
# system32 like the other builtins). With env.MADEIRA_DXC_NATIVE = 1 the Wine
# loader takes dxcompiler.dll from system32 instead of the game's folder (wine
# fork, dlls/ntdll/loader.c madeira_dxc_native); without it nothing changes.
# By default the DLL loads the game's dxil.dll for validation and signing, as
# Microsoft's build does; with env.MADEIRA_DXC_DXIL = 0 it validates with its
# built-in validator and signs the container itself (patches/0003).
#
# Source: microsoft/DirectXShaderCompiler v1.8.2407 (University of
# Illinois/NCSA licence) with patches/*.patch: raedrizqie's MinGW patch set
# (upstream PR #8265, not merged) adapted to 1.8.2407, ARM64EC fixes, and
# hexops' container signing (MIT); see notices/README.txt. The version string
# is pinned to Microsoft's build ("dxcoob 1.8.2407.7 (416fab6b5)"), so shader
# caches keyed on it stay valid.
#
# Needs: git, ninja, a host C++ compiler (for llvm-tblgen/clang-tblgen), CMake
# 3.x (DXC's CMake files are rejected by CMake 4), python3 and llvm-mingw
# 20260421 (LLVM_MINGW, default: the toolchains/ copy build-ipa.sh uses).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
WORK="${WORK:-$HERE/work}"
CMAKE="${CMAKE:-cmake}"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN)}"
export LLVM_MINGW="${LLVM_MINGW:-$REPO_ROOT/toolchains/llvm-mingw-20260421-ucrt-macos-universal}"
TAG=v1.8.2407
mkdir -p "$WORK"

if [ ! -d "$WORK/src/.git" ]; then
    git clone --depth 1 --branch "$TAG" --recurse-submodules --shallow-submodules \
        https://github.com/microsoft/DirectXShaderCompiler.git "$WORK/src"
    git -C "$WORK/src" -c user.name=madeira -c user.email=madeira@localhost am "$HERE"/patches/*.patch
fi

COMMON=(-G Ninja -C "$WORK/src/cmake/caches/PredefinedParams.cmake" -DCMAKE_BUILD_TYPE=Release
        -DLLVM_ENABLE_ASSERTIONS=OFF -DHLSL_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_TESTS=OFF
        -DCLANG_INCLUDE_TESTS=OFF -DSPIRV_BUILD_TESTS=OFF -DSPIRV_WERROR=OFF)

echo "=== host tablegen ==="
if [ ! -x "$WORK/build-host/bin/clang-tblgen" ]; then
    "$CMAKE" -S "$WORK/src" -B "$WORK/build-host" "${COMMON[@]}"
    ninja -C "$WORK/build-host" -j"$JOBS" llvm-tblgen clang-tblgen
fi

echo "=== dxcompiler.dll (arm64ec) ==="
# madeira-duo vk2: SPIR-V code generation on (DXC's official -spirv backend), so games on a Vulkan
# renderer (Path of Exile 2 with renderer_type=Vulkan compiles every shader with -spirv) can use the
# native compiler too. DXC_SPIRV_CODEGEN=OFF builds the DXIL-only compiler as before. This doesn't
# change DXIL output.
"$CMAKE" -S "$WORK/src" -B "$WORK/build-arm64ec" "${COMMON[@]}" \
    -DCMAKE_TOOLCHAIN_FILE="$HERE/toolchain-arm64ec.cmake" \
    -DENABLE_SPIRV_CODEGEN="${DXC_SPIRV_CODEGEN:-ON}" -DHLSL_BUILD_DXILCONV=OFF -DLLVM_BUILD_STATIC=ON -DHLSL_ENABLE_FIXED_VER=ON \
    -DLLVM_TABLEGEN="$WORK/build-host/bin/llvm-tblgen" \
    -DCLANG_TABLEGEN="$WORK/build-host/bin/clang-tblgen"
ninja -C "$WORK/build-arm64ec" -j"$JOBS" dxcompiler
OUT="${OUT:-$HERE/out}"
mkdir -p "$OUT"
"$LLVM_MINGW/bin/llvm-strip" --strip-debug -o "$OUT/dxcompiler.dll" "$WORK/build-arm64ec/bin/dxcompiler.dll"
python3 "$HERE/mark-builtin.py" --prefer-native "$OUT/dxcompiler.dll"
echo "  $(wc -c < "$OUT/dxcompiler.dll" | tr -d ' ') bytes, sha256 $( (shasum -a 256 "$OUT/dxcompiler.dll" 2>/dev/null || sha256sum "$OUT/dxcompiler.dll") | cut -c1-16)"
echo "  copy it to app/Madeira/arm64ec-windows/dxcompiler.dll to bundle it"
