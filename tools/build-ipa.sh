#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 8)}"
export ROOT JOBS

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || die "Madeira must be built on macOS with Xcode."
command -v xcodebuild >/dev/null || die "Xcode is required. Install it from the App Store first."
command -v xcrun >/dev/null || die "Xcode command-line tools are required."
command -v brew >/dev/null || die "Homebrew is required: https://brew.sh"
command -v python3 >/dev/null || die "python3 is required (ships with Xcode command-line tools)."

log "Installing build dependencies"
brew install cmake ninja meson pkg-config autoconf automake libtool bison flex sevenzip llvm || true

BISON_PATH="$(brew --prefix bison 2>/dev/null || true)/bin"
LLVM_PATH="$(brew --prefix llvm 2>/dev/null || true)/bin"
SEVENZIP_PATH="$(brew --prefix sevenzip 2>/dev/null || true)/bin"
if [[ -d "$BISON_PATH" ]]; then export PATH="$BISON_PATH:$PATH"; fi
if [[ -d "$LLVM_PATH" ]]; then export PATH="$LLVM_PATH:$PATH"; fi
if [[ -d "$SEVENZIP_PATH" ]]; then export PATH="$SEVENZIP_PATH:$PATH"; fi

log "Checking out submodules"
git -C "$ROOT" submodule update --init --recursive

log "Validating bundled Wine prefix"
bash "$ROOT/tools/check-prefix-template.sh" "$ROOT/app/Madeira/prefix-template.tar.gz"

"$ROOT/tools/build/setup-llvm-mingw.sh"
"$ROOT/tools/build/build-wine.sh"
"$ROOT/tools/build/build-fex-ios.sh"
"$ROOT/tools/build/build-freetype-ios.sh"

log "Building FFmpeg for iOS"
"$ROOT/build/ffmpeg/build.sh"

log "Building GnuTLS stack for iOS"
"$ROOT/build/gnutls-ios/build.sh"
"$ROOT/tools/build/sync-gnutls-libs.sh"

log "Bootstrapping wineserver"
"$ROOT/build/wineserver/bootstrap.sh"
"$ROOT/build/wineserver/build.sh"

log "Building Wine unix libraries"
"$ROOT/build/ntdll-unix/build.sh"
"$ROOT/build/win32u-unix/build.sh"

"$ROOT/tools/build/build-llvm-ios.sh"
"$ROOT/tools/build/build-shader-headers.sh"
"$ROOT/tools/build/build-dxmt-ios.sh"

if [[ "${MADEIRA_BUILD_I386:-1}" == "1" ]]; then
  log "Building i386 (WoW64) PE set"
  "$ROOT/build/wine-i386/build.sh"
fi

"$ROOT/tools/build/prepare-vcruntime.sh"

log "Staging bundled license texts"
bash "$ROOT/build/stage-licenses.sh"

"$ROOT/tools/build/package-ipa.sh"

printf '\n\033[1;32mDone: %s/dist/Madeira.ipa\033[0m\n' "$ROOT"
