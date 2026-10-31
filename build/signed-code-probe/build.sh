#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
sdk="${1:-iphoneos}"
case "$sdk" in
    iphoneos) target=arm64-apple-ios17.0; platform=iPhoneOS ;;
    macosx) target=arm64-apple-macos13.0; platform=MacOSX ;;
    *) echo "Usage: $0 [iphoneos|macosx]" >&2; exit 2 ;;
esac
out="out/$sdk/MadeiraSignedProbe.framework"
mkdir -p "$out"
xcrun --sdk "$sdk" clang -target "$target" -isysroot "$(xcrun --sdk "$sdk" --show-sdk-path)" \
    -dynamiclib fixture.S -o "$out/MadeiraSignedProbe" \
    -Wl,-install_name,@rpath/MadeiraSignedProbe.framework/MadeiraSignedProbe
cat > "$out/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.madeira.signed-code-probe</string>
<key>CFBundleExecutable</key><string>MadeiraSignedProbe</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleSupportedPlatforms</key><array><string>$platform</string></array>
</dict></plist>
EOF
# Ad hoc signing is sufficient for host checks. The installer must re-sign for iOS.
codesign --force --sign - --timestamp=none "$out"
codesign --verify --strict "$out"
echo "Built $PWD/$out (ad hoc; re-sign with the containing app before device use)."
