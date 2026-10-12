#!/usr/bin/env bash
set -euo pipefail
ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
DERIVED="$ROOT/app/DerivedData"
DIST="$ROOT/dist"
CONFIGURATION="${MADEIRA_CONFIGURATION:-Debug}"
APP="$DERIVED/Build/Products/${CONFIGURATION}-iphoneos/Madeira.app"

required=(
  "$ROOT/FEX/build-ios/FEXCore/Source/libFEXCore.a"
  "$ROOT/FEX/build-ios/FEXCore/Source/libFEXCore_Base.a"
  "$ROOT/FEX/build-ios/External/fmt/libfmt.a"
  "$ROOT/FEX/build-ios/External/cephes/libcephes_128bit.a"
  "$ROOT/app/Madeira/libwineserver.a"
  "$ROOT/app/Madeira/libntdll_unix.a"
  "$ROOT/app/Madeira/libwin32u_unix.a"
  "$ROOT/app/Madeira/libdxmt_combined.a"
)
for path in "${required[@]}"; do
  [[ -f "$path" ]] || { echo "ERROR: required build artifact missing: $path" >&2; exit 1; }
done

echo "=== Verifying libFEXCore_Base.a Allocator symbols before xcodebuild ==="
if command -v nm >/dev/null; then
  nm -gU "$ROOT/FEX/build-ios/FEXCore/Source/libFEXCore_Base.a" 2>/dev/null | grep 'Allocator.*memalign' || {
    echo "ERROR: FEXCore::Allocator::memalign symbol missing from libFEXCore_Base.a" >&2
    exit 1
  }
fi

rm -rf "$DERIVED" "$DIST/Payload"
mkdir -p "$DIST"

xcodebuild \
  -project "$ROOT/app/Madeira.xcodeproj" \
  -scheme Madeira \
  -configuration "$CONFIGURATION" \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED" \
  IPHONEOS_DEPLOYMENT_TARGET=17.0 \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY='' \
  build

[[ -d "$APP" ]] || { echo "ERROR: xcodebuild succeeded but Madeira.app is missing" >&2; exit 1; }

# Ship the optional 32-bit (WoW64) PE set when present
if [[ -d "$ROOT/app/Madeira/i386-windows" ]]; then
  echo "Bundling optional i386-windows (WoW64) PE set..."
  ditto "$ROOT/app/Madeira/i386-windows" "$APP/i386-windows"
fi

if [[ -d "$ROOT/app/Madeira/d3d12" ]]; then
  echo "Bundling D3D12 runtime support..."
  ditto "$ROOT/app/Madeira/d3d12" "$APP/d3d12"
fi

if [[ -d "$ROOT/app/Madeira/x86_64-vcruntime" && ! -d "$APP/x86_64-vcruntime" ]]; then
  echo "Bundling x86_64-vcruntime..."
  ditto "$ROOT/app/Madeira/x86_64-vcruntime" "$APP/x86_64-vcruntime"
fi

# Preserve Madeira's requested JIT/debug entitlements in the IPA. SideStore will
# replace this ad-hoc signature with the user's development signature while
# retaining the supported entitlements.
codesign --force --sign - \
  --entitlements "$ROOT/app/Madeira/Madeira.entitlements" \
  "$APP"

bundle_required=(
  "$APP/Madeira"
  "$APP/prefix-template.tar.gz"
  "$APP/arm64ec-windows/xtajit64.dll"
  "$APP/x86_64-vcruntime/vcruntime140.dll"
)
for path in "${bundle_required[@]}"; do
  [[ -e "$path" ]] || { echo "ERROR: required bundle resource missing: $path" >&2; exit 1; }
done
codesign -d --entitlements :- "$APP" 2>/dev/null | grep -q 'com.apple.security.cs.allow-jit' || {
  echo "ERROR: packaged app is missing the allow-jit entitlement" >&2
  exit 1
}

mkdir -p "$DIST/Payload"
ditto "$APP" "$DIST/Payload/Madeira.app"
rm -f "$DIST/Madeira.ipa"
(
  cd "$DIST"
  /usr/bin/zip -qry Madeira.ipa Payload
)
rm -rf "$DIST/Payload"
[[ -s "$DIST/Madeira.ipa" ]] || { echo "ERROR: failed to create IPA" >&2; exit 1; }
unzip -tq "$DIST/Madeira.ipa" >/dev/null
