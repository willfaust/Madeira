#!/bin/bash
# Invoked by Xcode after resources are copied, before the app is signed.
set -euo pipefail
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP="${CODESIGNING_FOLDER_PATH:?Xcode bundle path is required}"
OUT="$R/build/moltenvk-ios/out"
# Inspect the library, rather than relying on an environment variable surviving
# from the native build into Xcode. Disabled builds remove any previous bundle.
SYMBOLS="$(xcrun nm -u "$R/app/Madeira/libwin32u_unix.a")"
if ! grep -q '_madeira_vulkan_layer_lease_create' <<< "$SYMBOLS"; then
    rm -rf "$APP/Frameworks/MoltenVK.framework" "$APP/licenses/moltenvk"
    exit 0
fi
[[ -f "$OUT/MoltenVK.framework/MoltenVK" ]] || { echo "error: run build/moltenvk-ios/build.sh" >&2; exit 1; }
for dll in winevulkan.dll vulkan-1.dll; do
    [[ -f "$R/app/Madeira/arm64ec-windows/$dll" ]] || { echo "error: missing $dll; run build/moltenvk-ios/build-pe.sh" >&2; exit 1; }
done
NT_SYMBOLS="$(xcrun nm -gU "$R/app/Madeira/libntdll_unix.a")"
grep -q '_winevulkan_unix_call_funcs' <<< "$NT_SYMBOLS" || { echo "error: rebuild ntdll with MADEIRA_MOLTENVK=1" >&2; exit 1; }
python3 - "$OUT" <<'PY'
import hashlib, json, pathlib, sys
out = pathlib.Path(sys.argv[1])
r = json.loads((out / 'source.json').read_text())
if r['commit'] != 'db445ff2042d9ce348c439ad8451112f354b8d2a' or r['geometry_overlay']:
    raise SystemExit('error: unexpected MoltenVK source receipt')
if hashlib.sha256((out / 'MoltenVK.framework/MoltenVK').read_bytes()).hexdigest() != r['sha256']:
    raise SystemExit('error: staged MoltenVK binary changed')
PY
mkdir -p "$APP/Frameworks" "$APP/licenses/moltenvk"
rm -rf "$APP/Frameworks/MoltenVK.framework"
ditto "$OUT/MoltenVK.framework" "$APP/Frameworks/MoltenVK.framework"
ditto "$OUT/licenses" "$APP/licenses/moltenvk"
cp "$OUT/source.json" "$APP/licenses/moltenvk/source.json"
if [[ "${CODE_SIGNING_ALLOWED:-YES}" != NO ]]; then
    codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" --timestamp=none \
        "$APP/Frameworks/MoltenVK.framework"
fi
