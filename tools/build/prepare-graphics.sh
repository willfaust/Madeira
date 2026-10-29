#!/usr/bin/env bash
# Bootstrap the existing graphics recipes with immutable source versions.
set -euo pipefail
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
C="$R/toolchains/graphics"
mkdir -p "$C" "$R/app/Madeira/licenses"
export JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"
checkout() {
    local dest=$1 url=$2 commit=$3
    if [ ! -d "$dest/.git" ]; then
        git init -q "$dest"
        git -C "$dest" fetch --depth 1 "$url" "$commit"
        git -C "$dest" checkout -q FETCH_HEAD
    fi
    [ "$(git -C "$dest" rev-parse HEAD)" = "$commit" ] || {
        echo "Wrong source version at $dest; use a separate checkout" >&2; exit 1;
    }
}
mesa() {
    local version=$1 sha=$2
    if [ ! -f "$C/mesa-$version.tar.xz" ]; then
        curl -fL --retry 3 "https://archive.mesa3d.org/mesa-$version.tar.xz" -o "$C/mesa-$version.tar.xz.part"
        mv "$C/mesa-$version.tar.xz.part" "$C/mesa-$version.tar.xz"
    fi
    [ "$(shasum -a 256 "$C/mesa-$version.tar.xz" | cut -d' ' -f1)" = "$sha" ] || {
        echo "Mesa $version checksum mismatch" >&2; exit 1;
    }
    # A recipe change gets fresh patch inputs and a separate build directory.
    local recipe
    recipe=$(python3 "$R/tools/build/runtime-components.py" key "$COMPONENT" | cut -d= -f2)
    export GRAPHICS_WORK="$C/$recipe"
    mkdir -p "$GRAPHICS_WORK"
    [ -d "$GRAPHICS_WORK/mesa-$version" ] || tar -xJf "$C/mesa-$version.tar.xz" -C "$GRAPHICS_WORK"
    export MESA_SRC="$GRAPHICS_WORK/mesa-$version"
}
python_tools() {
    export MESA_VENV="$C/venv-1.9.1"
    if [ ! -x "$MESA_VENV/bin/meson" ]; then
        python3 -m venv "$MESA_VENV"
        "$MESA_VENV/bin/pip" install meson==1.9.1 mako==1.3.10 pyyaml==6.0.3 packaging==25.0 ninja==1.13.0
    fi
    export PATH="$MESA_VENV/bin:$PATH"
}
case "${1:-}" in
  moltenvk|zink)
    export MOLTENVK_SRC="$C/MoltenVK-db66022459ffb663aa2b50f6b018bc2e124f5edf"
    checkout "$MOLTENVK_SRC" https://github.com/KhronosGroup/MoltenVK.git db66022459ffb663aa2b50f6b018bc2e124f5edf
    if [ "$1" = moltenvk ]; then
        bash "$R/build/moltenvk-ios/build.sh"
    else
        python_tools
        COMPONENT=zink
        mesa 25.0.7 592272df3cf01e85e7db300c449df5061092574d099da275d19e97ef0510f8a6
        MESA_BUILD="$GRAPHICS_WORK/obj" bash "$R/build/mesa-ios/build.sh"
    fi
    ;;
  kosmickrisp)
    python_tools
    COMPONENT=kosmickrisp
    mesa 26.2.4 bce5f7fbebb934373b86c999a064d52fb5065878dc57f287f95346648ec832e9
    LLVM="$(brew --prefix llvm@21)"
    TRANSLATOR="$C/SPIRV-LLVM-Translator-29758b55816c14abb3e4142d42aca7a95bf46710"
    checkout "$TRANSLATOR" https://github.com/KhronosGroup/SPIRV-LLVM-Translator.git 29758b55816c14abb3e4142d42aca7a95bf46710
    export KK_LLVM_CONFIG="$LLVM/bin/llvm-config"
    export KK_HOST_PKG_CONFIG_PATH="$C/translator-install/lib/pkgconfig:$(brew --prefix spirv-tools)/lib/pkgconfig"
    if [ ! -f "$C/translator-install/lib/pkgconfig/LLVMSPIRVLib.pc" ]; then
        cmake -S "$TRANSLATOR" -B "$C/translator-build" -G Ninja \
            -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$C/translator-install" \
            -DLLVM_DIR="$LLVM/lib/cmake/llvm" -DBUILD_SHARED_LIBS=ON \
            -DLLVM_SPIRV_INCLUDE_TESTS=OFF
        cmake --build "$C/translator-build" --parallel "$JOBS"
        cmake --install "$C/translator-build"
    fi
    export PATH="$LLVM/bin:$PATH"
    KK_WORK="$GRAPHICS_WORK" KK_MESA_SRC="$MESA_SRC" KK_OUT="$R/app/Madeira/gl" \
        bash "$R/build/mesa-ios/build-kosmickrisp.sh"
    cp "$MESA_SRC/docs/license.rst" "$R/app/Madeira/licenses/KosmicKrisp-Mesa-license.rst"
    ;;
  *) echo 'Expected moltenvk, zink, or kosmickrisp' >&2; exit 2 ;;
esac
