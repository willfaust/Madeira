#!/bin/bash
# Build stock MoltenVK from an immutable source pin. Apple compilation only.
set -euo pipefail
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PIN=db445ff2042d9ce348c439ad8451112f354b8d2a
SRC="$R/toolchains/MoltenVK-v1.4.1"
OUT="$R/build/moltenvk-ios/out"
[[ "$(uname -s)" == Darwin ]] || { echo "macOS with Xcode is required" >&2; exit 1; }
command -v xcodebuild >/dev/null
if [[ ! -d "$SRC/.git" ]]; then
    mkdir -p "$SRC"
    git -C "$SRC" init
    git -C "$SRC" remote add origin https://github.com/KhronosGroup/MoltenVK.git
    git -C "$SRC" fetch --depth 1 origin "$PIN"
    git -C "$SRC" checkout --detach FETCH_HEAD
fi
[[ "$(git -C "$SRC" rev-parse HEAD)" == "$PIN" ]] || { echo "Unexpected MoltenVK revision" >&2; exit 1; }
git -C "$SRC" diff --quiet HEAD --
(cd "$SRC" && ./fetchDependencies --ios)
# fetchDependencies reads these pins from the checked-out MoltenVK source.
for dep in cereal SPIRV-Cross SPIRV-Tools Vulkan-Headers; do
    [[ "$(git -C "$SRC/External/$dep" rev-parse HEAD)" == "$(tr -d '\r\n' < "$SRC/ExternalRevisions/${dep}_repo_revision")" ]]
done
[[ "$(git -C "$SRC/External/SPIRV-Tools/external/spirv-headers" rev-parse HEAD)" == "$(tr -d '\r\n' < "$SRC/ExternalRevisions/SPIRV-Headers_repo_revision")" ]]
(cd "$SRC" && xcodebuild build -project MoltenVKPackaging.xcodeproj \
    -scheme 'MoltenVK Package (iOS only)' -configuration Release \
    -destination 'generic/platform=iOS' \
    'GCC_PREPROCESSOR_DEFINITIONS=$(inherited) MVK_HIDE_VULKAN_SYMBOLS=0' \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=NO IPHONEOS_DEPLOYMENT_TARGET=17.0)
mkdir -p "$OUT"
python3 - "$SRC" "$OUT" <<'PY'
import hashlib, json, pathlib, plistlib, shutil, sys
src, out = map(pathlib.Path, sys.argv[1:])
xc = src / 'Package/Release/MoltenVK/dynamic/MoltenVK.xcframework'
info = plistlib.loads((xc / 'Info.plist').read_bytes())
matches = [x for x in info['AvailableLibraries']
           if x['SupportedPlatform'] == 'ios' and not x.get('SupportedPlatformVariant')
           and x['SupportedArchitectures'] == ['arm64']]
if len(matches) != 1:
    raise SystemExit('Expected one iOS arm64 device framework')
entry = matches[0]
framework = xc / entry['LibraryIdentifier'] / entry['LibraryPath']
target = out / 'MoltenVK.framework'
if target.exists(): shutil.rmtree(target)
shutil.copytree(framework, target, symlinks=True)
licenses = out / 'licenses'
licenses.mkdir(exist_ok=True)
shutil.copy2(src / 'LICENSE', licenses / 'MoltenVK-LICENSE.txt')
for name in ('cereal', 'SPIRV-Cross', 'SPIRV-Tools'):
    shutil.copy2(src / 'External' / name / 'LICENSE', licenses / (name + '-LICENSE.txt'))
shutil.copy2(src / 'External/SPIRV-Tools/external/spirv-headers/LICENSE', licenses / 'SPIRV-Headers-LICENSE.txt')
shutil.copy2(src / 'External/Vulkan-Headers/LICENSE.md', licenses / 'Vulkan-Headers-LICENSE.md')
shutil.copytree(src / 'External/Vulkan-Headers/LICENSES', licenses / 'Vulkan-Headers', dirs_exist_ok=True)
receipt = {
    'repository': 'https://github.com/KhronosGroup/MoltenVK',
    'commit': 'db445ff2042d9ce348c439ad8451112f354b8d2a',
    'version': '1.4.1', 'geometry_overlay': False,
    'sha256': hashlib.sha256((target / 'MoltenVK').read_bytes()).hexdigest(),
}
(out / 'source.json').write_text(json.dumps(receipt, indent=2) + '\n')
PY
xcrun lipo -archs "$OUT/MoltenVK.framework/MoltenVK" | grep -qx arm64
xcrun vtool -show-build "$OUT/MoltenVK.framework/MoltenVK" | grep -Eq 'platform[[:space:]]+IOS$'
SYMBOLS="$(xcrun nm -gU "$OUT/MoltenVK.framework/MoltenVK")"
grep -q ' _vkGetInstanceProcAddr$' <<< "$SYMBOLS"
grep -q ' _vkGetDeviceProcAddr$' <<< "$SYMBOLS"
echo "Staged stock MoltenVK v1.4.1. App build and device rendering are still required."
