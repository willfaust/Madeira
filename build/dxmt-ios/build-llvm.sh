#!/bin/bash
# Build the host table generator and the LLVM 15 libraries used by airconv.
set -euo pipefail

BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$BUILD_DIR/../.." && pwd)"
LLVM_REVISION=8dfdcc7b7bf66834a761bd8de445840ef68e4d1a # llvmorg-15.0.7
LLVM_PROJECT="$REPO_ROOT/toolchains/llvm-project"
LLVM_HOST="$REPO_ROOT/toolchains/llvm-host-build"
LLVM_BUILD="$REPO_ROOT/toolchains/llvm-ios-build"
IOS_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET:-18.0}"
JOBS="${JOBS:-3}"

[[ $(uname -s) == Darwin ]] || { echo 'LLVM iOS requires macOS and Xcode.' >&2; exit 1; }
for tool in cmake ninja xcrun python3 curl; do
    command -v "$tool" >/dev/null || { echo "Missing build tool: $tool" >&2; exit 1; }
done
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
MACOS_SDK="$(xcrun --sdk macosx --show-sdk-path)"
CLANG="$(xcrun --find clang)"
CLANGXX="$(xcrun --find clang++)"

# Download an immutable revision; do not depend on an unpinned branch checkout.
# Only LLVM and its shared CMake modules are needed from the monorepo.
mkdir -p "$REPO_ROOT/toolchains"
if [[ ! -d "$LLVM_PROJECT" ]]; then
    STAGING="$(mktemp -d "${TMPDIR:-/tmp}/llvm-source.XXXXXX")"
    trap 'rm -rf "$STAGING"' EXIT
    curl --fail --silent --show-error --location --retry 3 \
        --connect-timeout 30 --max-time 600 --proto '=https' --proto-redir '=https' \
        "https://codeload.github.com/llvm/llvm-project/tar.gz/$LLVM_REVISION" \
        --output "$STAGING/source.tar.gz"
    mkdir "$STAGING/source"
    tar -xzf "$STAGING/source.tar.gz" --strip-components=1 -C "$STAGING/source" \
        "llvm-project-$LLVM_REVISION/llvm" "llvm-project-$LLVM_REVISION/cmake"
    printf '%s\n' "$LLVM_REVISION" > "$STAGING/source/.uncrashed-llvm-revision"
    mv "$STAGING/source" "$LLVM_PROJECT"
    rm -rf "$STAGING"
    trap - EXIT
fi
if [[ -f "$LLVM_PROJECT/.uncrashed-llvm-revision" ]]; then
    ACTUAL_REVISION="$(cat "$LLVM_PROJECT/.uncrashed-llvm-revision")"
elif [[ -e "$LLVM_PROJECT/.git" ]]; then
    ACTUAL_REVISION="$(git -C "$LLVM_PROJECT" rev-parse HEAD)"
else
    echo "Unrecognized LLVM sources at $LLVM_PROJECT; move them aside and rerun." >&2
    exit 1
fi
[[ "$ACTUAL_REVISION" == "$LLVM_REVISION" ]] || {
    echo "Expected LLVM 15.0.7 ($LLVM_REVISION), found $ACTUAL_REVISION." >&2
    exit 1
}

COMMON_CMAKE=(
    -G Ninja -DCMAKE_BUILD_TYPE=Release
    "-DCMAKE_C_COMPILER=$CLANG" "-DCMAKE_CXX_COMPILER=$CLANGXX"
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5
    '-DLLVM_TARGETS_TO_BUILD=' '-DLLVM_ENABLE_PROJECTS='
    -DLLVM_ENABLE_ASSERTIONS=OFF -DLLVM_ENABLE_EH=OFF -DLLVM_ENABLE_RTTI=OFF
    -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF -DLLVM_INCLUDE_BENCHMARKS=OFF
    -DLLVM_INCLUDE_DOCS=OFF -DLLVM_ENABLE_BINDINGS=OFF
    -DLLVM_ENABLE_ZLIB=OFF -DLLVM_ENABLE_ZSTD=OFF -DLLVM_ENABLE_LIBXML2=OFF
    -DLLVM_ENABLE_TERMINFO=OFF -DLLVM_ENABLE_LIBEDIT=OFF
    -DLLVM_BUILD_LLVM_DYLIB=OFF -DLLVM_LINK_LLVM_DYLIB=OFF -DBUILD_SHARED_LIBS=OFF
)

echo 'Building LLVM 15.0.7 table generator for the macOS host'
SDKROOT="$MACOS_SDK" cmake -S "$LLVM_PROJECT/llvm" -B "$LLVM_HOST" "${COMMON_CMAKE[@]}" \
    "-DCMAKE_OSX_SYSROOT=$MACOS_SDK" "-DCMAKE_OSX_ARCHITECTURES=$(uname -m)"
cmake --build "$LLVM_HOST" --target llvm-tblgen --parallel "$JOBS"

echo 'Building LLVM 15.0.7 static libraries for iOS arm64'
SDKROOT="$SDK" cmake -S "$LLVM_PROJECT/llvm" -B "$LLVM_BUILD" "${COMMON_CMAKE[@]}" \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_SYSTEM_PROCESSOR=arm64 \
    "-DCMAKE_OSX_SYSROOT=$SDK" -DCMAKE_OSX_ARCHITECTURES=arm64 \
    "-DCMAKE_OSX_DEPLOYMENT_TARGET=$IOS_DEPLOYMENT_TARGET" \
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
    -DLLVM_HOST_TRIPLE=aarch64-apple-ios -DLLVM_DEFAULT_TARGET_TRIPLE=aarch64-apple-ios \
    "-DLLVM_TABLEGEN=$LLVM_HOST/bin/llvm-tblgen" \
    -DLLVM_INCLUDE_TOOLS=OFF -DLLVM_INCLUDE_UTILS=OFF -DLLVM_BUILD_UTILS=OFF \
    -DLLVM_ENABLE_THREADS=ON -DLLVM_ENABLE_BACKTRACES=OFF -DLLVM_ENABLE_CRASH_OVERRIDES=OFF \
    -DLLVM_ENABLE_PLUGINS=OFF -DLLVM_NO_DEAD_STRIP=ON
# LLVM 15's add_link_opts otherwise passes --gc-sections on iOS. Static
# archives do not need linker dead stripping; Xcode strips the final app.
# These two targets build their transitive component dependencies as well.
cmake --build "$LLVM_BUILD" --target LLVMPasses LLVMBitWriter --parallel "$JOBS"

for archive in "$LLVM_BUILD"/lib/libLLVM*.a; do
    python3 "$REPO_ROOT/tools/validate-ios-bundle.py" --archive "$archive"
done
test -s "$LLVM_BUILD/include/llvm/Config/llvm-config.h"
test -s "$LLVM_BUILD/lib/libLLVMPasses.a"
test -s "$LLVM_BUILD/lib/libLLVMBitWriter.a"
printf 'LLVM %s for iOS %s arm64\n' "$LLVM_REVISION" "$IOS_DEPLOYMENT_TARGET" > "$LLVM_BUILD/uncrashed-build.txt"
echo "LLVM ready: $LLVM_BUILD"
