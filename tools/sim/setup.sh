#!/usr/bin/env bash
# Build Madeira for the iOS Simulator, install it on an iPhone and an iPad simulator and launch it.
#
#   tools/sim/setup.sh            # build, install, launch, screenshot (needs the device runtime built once)
#   tools/sim/setup.sh --runtime  # build the device runtime first (tools/build-ipa.sh)
#   SIM_WITH_IPAD=1 tools/sim/setup.sh   # also install on an iPad simulator
#
# What this runs is the real app UI. Games do not run: the native archives are the device builds relabelled
# for the simulator (relabel-archives.py), and FEXBridge.mm, WiniosGL.m and MetalFX are replaced by SimStubs.m.
# Pick devices with SIM_IPHONE and SIM_IPAD (name or UDID); the newest installed ones are used otherwise.
# An iPad is used only with SIM_WITH_IPAD=1 or SIM_IPAD.
# Output (build, logs, screenshots): build/sim/
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$ROOT/build/sim"; LIB="$OUT/lib"; DERIVED="$OUT/DerivedData"
export PATH="/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:$PATH"
say() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
mkdir -p "$LIB" "$OUT/shots"

[ "${1:-}" = "--runtime" ] && { say "device runtime (tools/build-ipa.sh)"; "$ROOT/tools/build-ipa.sh"; }

say "preflight"
command -v xcodebuild >/dev/null || die "Xcode is required"
xcrun --find metal >/dev/null 2>&1 || xcodebuild -downloadComponent MetalToolchain
for f in app/Madeira/libntdll_unix.a app/Madeira/libwineserver.a app/Madeira/libwin32u_unix.a app/Madeira/libdxmt_combined.a \
         FEX/build-ios/FEXCore/Source/libFEXCore.a app/Madeira/x86_64-vcruntime/vcruntime140.dll; do
  [ -e "$ROOT/$f" ] || die "$f is missing: run tools/sim/setup.sh --runtime (or tools/build-ipa.sh) once"
done
command -v cargo >/dev/null || die "cargo is missing: install rustup (BUILDING.md)"

say "devices"
pick() { # kind (iPhone|iPad), wanted name or UDID -> UDID of that device or the newest available of the kind
  python3 - "$1" "${2:-}" <<'PY'
import json, subprocess, sys
kind, want = sys.argv[1], sys.argv[2]
d = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "-j", "devices", "available"]))["devices"]
def ver(rt):  # com.apple.CoreSimulator.SimRuntime.iOS-27-0 -> (27, 0)
    return tuple(int(x) for x in rt.rsplit("iOS-", 1)[1].split("-")) if "iOS-" in rt else (0,)
best = None
for rt in sorted(d, key=ver, reverse=True):
    for dev in d[rt]:
        if want and want in (dev["name"], dev["udid"]): print(dev["udid"]); sys.exit()
        if not want and best is None and dev["name"].startswith(kind) and "iOS-" in rt: best = dev["udid"]
print(best or "")
PY
}
IPHONE="$(pick iPhone "${SIM_IPHONE:-}")"; [ -n "$IPHONE" ] || die "no iPhone simulator"
DEVICES=("$IPHONE"); IPAD=""
if [ -n "${SIM_WITH_IPAD:-}${SIM_IPAD:-}" ]; then
  IPAD="$(pick iPad "${SIM_IPAD:-}")"; [ -n "$IPAD" ] || die "no iPad simulator"; DEVICES+=("$IPAD")
fi
echo "iPhone $IPHONE${IPAD:+, iPad $IPAD}"
for d in "${DEVICES[@]}"; do xcrun simctl boot "$d" 2>/dev/null || true; done
open -b com.apple.iphonesimulator || true

say "native archives for the simulator"
FEXLIBS=(FEXCore/Source/libFEXCore.a FEXCore/Source/libFEXCore_Base.a FEXCore/Source/libJemallocLibs.a External/fmt/libfmt.a
         External/cephes/libcephes_128bit.a External/xxhash/cmake_unofficial/libxxhash.a External/SoftFloat-3e/libsoftfloat_3e.a)
python3 -I "$ROOT/tools/sim/relabel-archives.py" "$LIB" "$ROOT"/app/Madeira/lib*.a "$ROOT/app/libdxmt_unix.a" \
  $(for l in "${FEXLIBS[@]}"; do [ -e "$ROOT/FEX/build-ios/$l" ] && echo "$ROOT/FEX/build-ios/$l"; done) >/dev/null
# Rust objects name their platform differently: build the pairing library for the simulator target.
( cd "$ROOT/build/rppairing-ios" && rustup target add aarch64-apple-ios-sim >/dev/null 2>&1 &&
  IPHONEOS_DEPLOYMENT_TARGET=18.0 cargo build --release --locked --target aarch64-apple-ios-sim >/dev/null 2>&1 &&
  cp target/aarch64-apple-ios-sim/release/libmadeira_rppairing.a "$LIB/libmadeira_rppairing.a" )
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
clang -target arm64-apple-ios18.0-simulator -isysroot "$SDK" -fobjc-arc -c "$ROOT/tools/sim/SimStubs.m" -o "$OUT/SimStubs.o"
rm -f "$LIB/libsimstubs.a"; ar rcs "$LIB/libsimstubs.a" "$OUT/SimStubs.o"

say "licences and project"
bash "$ROOT/build/stage-licenses.sh" >/dev/null
python3 -I "$ROOT/tools/sim/make-sim-project.py"

# Keychain access (Steam, itch.io sign-in tokens) on the simulator reads the app's entitlements from a section of
# the binary, as Xcode's own simulator builds embed them; without it every sign-in fails with "keychain-store failed".
# (Signing them in with codesign makes the simulator refuse to launch the app.)
BUNDLE_ID="$(sed -n 's/.*MADEIRA_BUNDLE_IDENTIFIER = \(.*\);/\1/p' "$ROOT/app/Madeira.xcodeproj/project.pbxproj" | head -1)"
[ -n "$BUNDLE_ID" ] || die "bundle identifier not found in the Xcode project"
cat > "$OUT/sim.entitlements" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>application-identifier</key><string>SIM0000000.$BUNDLE_ID</string>
<key>keychain-access-groups</key><array><string>SIM0000000.$BUNDLE_ID</string></array>
</dict></plist>
PLIST

say "build (iOS 18.0, Debug)"
xcodebuild build -project "$ROOT/app/MadeiraSim.xcodeproj" -scheme Madeira -configuration Debug \
  -destination "platform=iOS Simulator,id=$IPHONE" -derivedDataPath "$DERIVED" \
  IPHONEOS_DEPLOYMENT_TARGET=18.0 CODE_SIGNING_ALLOWED=NO ENABLE_DEBUG_DYLIB=NO \
  EXCLUDED_SOURCE_FILE_NAMES="FEXBridge.mm WiniosGL.m" LIBRARY_SEARCH_PATHS="$LIB" \
  OTHER_LDFLAGS="\$(inherited) -force_load $LIB/libsimstubs.a -Wl,-sectcreate,__TEXT,__entitlements,$OUT/sim.entitlements" > "$OUT/build.log" 2>&1 \
  || { grep -E 'error:|^ld:' "$OUT/build.log" | sort -u | head -20; die "build failed, see $OUT/build.log"; }
APP="$DERIVED/Build/Products/Debug-iphonesimulator/Madeira.app"
BID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Info.plist")"
# The device entitlements (extended addressing, JIT) stop a simulator app from launching: sign without them.
codesign --force --deep --sign - "$APP"

say "install and launch $BID"
for d in "${DEVICES[@]}"; do
  xcrun simctl terminate "$d" "$BID" 2>/dev/null || true
  xcrun simctl install "$d" "$APP"
  # Opens the library instead of first-run setup (OnboardingRules.revisionKey); SKIP_ONBOARDING=0 keeps setup.
  [ "${SKIP_ONBOARDING:-1}" = 0 ] || xcrun simctl spawn "$d" defaults write "$BID" madeiraOnboardingRevision -int 99
  xcrun simctl launch "$d" "$BID"
done
sleep 8
xcrun simctl io "$IPHONE" screenshot "$OUT/shots/iphone-launch.png" 2>/dev/null
[ -z "$IPAD" ] || xcrun simctl io "$IPAD" screenshot "$OUT/shots/ipad-launch.png" 2>/dev/null
echo "$IPHONE" > "$OUT/iphone.udid"; [ -z "$IPAD" ] || echo "$IPAD" > "$OUT/ipad.udid"; echo "$BID" > "$OUT/bundle.id"
say "done: screenshots in $OUT/shots"
