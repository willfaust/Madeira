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
brew install cmake ninja meson pkg-config autoconf automake libtool bison flex sevenzip llvm
export PATH="$(brew --prefix bison)/bin:$(brew --prefix llvm)/bin:$PATH"

log "Checking out submodules"
git -C "$ROOT" submodule update --init --recursive

log "Validating bundled Wine prefix"
bash "$ROOT/tools/check-prefix-template.sh" "$ROOT/app/Madeira/prefix-template.tar.gz"

"$ROOT/tools/build/setup-llvm-mingw.sh"
# Madeira Dock: without dockhost.exe in the bundle the app hides Dock and the Steam library.
log "Building Madeira Dock"
"$ROOT/build/madeira-dock/build.sh"
"$ROOT/tools/build/build-wine.sh"
"$ROOT/tools/build/build-fex-ios.sh"
"$ROOT/build/rppairing-ios/build.sh"
"$ROOT/tools/build/build-freetype-ios.sh"

log "Building GnuTLS stack for iOS"
"$ROOT/build/gnutls-ios/build.sh"
"$ROOT/tools/build/sync-gnutls-libs.sh"

log "Building FFmpeg for iOS"
"$ROOT/build/ffmpeg/build.sh"

log "Bootstrapping wineserver"
"$ROOT/build/wineserver/build.sh"

log "Building Wine unix libraries"
"$ROOT/build/ntdll-unix/build.sh"
"$ROOT/build/win32u-unix/build.sh"

"$ROOT/tools/build/build-llvm-ios.sh"
# Xcode 26 installs the Metal compiler separately; returns at once when present.
xcodebuild -downloadComponent MetalToolchain >/dev/null 2>&1 || true
"$ROOT/tools/build/build-shader-headers.sh"
"$ROOT/tools/build/build-dxmt-ios.sh"
"$ROOT/tools/build/prepare-vcruntime.sh"
"$ROOT/build/stage-licenses.sh"

log "Building and verifying the bundled runtime components"
# Local builds rebuild from source. CI may reuse only fully verified inputs.
python3 "$ROOT/tools/build/runtime-components.py" build all
if [[ "${GITHUB_ACTIONS:-}" != true ]]; then
  "$ROOT/build/wine-i386/build.sh"
fi
"$ROOT/tools/build/package-ipa.sh"

printf '\n\033[1;32mDone: %s/dist/Madeira.ipa\033[0m\n' "$ROOT"
