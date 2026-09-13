#!/bin/bash
# Build Madeira.app for arm64 and package it as an unsigned .ipa for sideloading.
#
# Why unsigned: JIT needs a debugger to attach, so this app cannot go through
# the App Store — it is installed by sideloading, and the sideloader re-signs it
# with the user's own Apple ID. That re-sign is also where the JIT entitlements
# come from (app/Madeira/Madeira.entitlements). Signing here would only produce
# an IPA bound to this machine's identity, which is not what a sideloader wants.
#
# Works two ways: on a Mac whose tree already built these archives, and as the
# packaging step of .github/workflows/ipa.yml, which builds all 15 from the
# pinned sources first. 11 of the 15 are gitignored build products (FEX,
# wineserver/ntdll/win32u, DXMT) and the three submodules are empty in a clean
# clone, so a bare checkout cannot be linked at all. That is checked below
# before any compiler starts, so the failure names the missing archive instead
# of surfacing as "library not found".
#
# Usage:
#   scripts/make-ipa.sh [--output PATH] [--configuration Release|Debug] [--keep-build]
#
# Default output: Madeira-unsigned.ipa in the repo root.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

OUTPUT="$ROOT/Madeira-unsigned.ipa"
CONFIGURATION="Release"
KEEP_BUILD=0

while [ $# -gt 0 ]; do
    case "$1" in
        --output)        OUTPUT="$2"; shift 2 ;;
        --configuration) CONFIGURATION="$2"; shift 2 ;;
        --keep-build)    KEEP_BUILD=1; shift ;;
        -h|--help)       sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

# Xcode only runs on macOS, and this build needs the iPhoneOS SDK.
if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "make-ipa: xcodebuild not found. Run this on macOS with Xcode installed." >&2
    exit 1
fi
if ! xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1; then
    echo "make-ipa: no iPhoneOS SDK. Install one via Xcode > Settings > Components." >&2
    exit 1
fi

# Fail here, with the real reason, rather than inside ld.
tools/check-build-inputs.sh

BUILD_DIR="$ROOT/build/ipa-build"
STAGE="$ROOT/build/ipa-stage"

rm -rf "$BUILD_DIR" "$STAGE"
mkdir -p "$BUILD_DIR" "$STAGE"

echo ""
echo "==> Building Madeira ($CONFIGURATION, arm64, unsigned)"
xcodebuild \
    -project app/Madeira.xcodeproj \
    -target Madeira \
    -configuration "$CONFIGURATION" \
    -sdk iphoneos \
    -arch arm64 \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    CONFIGURATION_BUILD_DIR="$BUILD_DIR" \
    build

APP="$BUILD_DIR/Madeira.app"
[ -d "$APP" ] || { echo "make-ipa: no app at $APP" >&2; exit 1; }

echo ""
echo "==> Packaging Payload/Madeira.app as an .ipa"
mkdir -p "$STAGE/Payload"
cp -R "$APP" "$STAGE/Payload/"

rm -f "$OUTPUT"
mkdir -p "$(dirname "$OUTPUT")"
# ditto is the correct tool for a bundle: it preserves symlinks and the
# extended attributes a plain zip can drop.
if command -v ditto >/dev/null 2>&1; then
    ( cd "$STAGE" && ditto -c -k --norsrc --keepParent Payload "$OUTPUT" )
else
    ( cd "$STAGE" && zip -qry "$OUTPUT" Payload )
fi

# Bundle id must match app/source.json and scripts/deploy-thumper.sh, or
# sideload tooling targets the wrong app. A mismatch has bitten this repo before.
BUILT_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Info.plist")
EXPECTED_ID="com.madeira.emulator"
if [ "$BUILT_ID" != "$EXPECTED_ID" ]; then
    echo "make-ipa: bundle id is '$BUILT_ID', expected '$EXPECTED_ID'" >&2
    echo "  app/source.json and deploy-thumper.sh assume the latter." >&2
    exit 1
fi

[ "$KEEP_BUILD" -eq 1 ] || rm -rf "$BUILD_DIR" "$STAGE"

echo ""
echo "==> Done"
echo "    $OUTPUT"
echo "    $(du -h "$OUTPUT" | awk '{print $1}'), bundle id $BUILT_ID, unsigned"
echo ""
echo "    Install with your sideloader of choice. It re-signs with your Apple ID;"
echo "    note README's warning that extended-virtual-addressing is not available"
echo "    on a free Apple ID, so some builds need a paid account."
