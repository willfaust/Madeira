#!/bin/bash
# Builds MadeiraLoopback.appex (Madeira's own VPN for built-in JIT) for iOS arm64, with the
# app's version, into build/madeira-loopback/build/Release-iphoneos/. Embed it in
# Madeira.app/PlugIns before signing; the sign script gives it <bundle>.Loopback.
#   build.sh <CURRENT_PROJECT_VERSION> <MARKETING_VERSION>
set -euo pipefail
cd "$(dirname "$0")"
xcodegen generate --quiet
xcodebuild -project MadeiraLoopback.xcodeproj -target MadeiraLoopback -configuration Release -sdk iphoneos \
  CODE_SIGNING_ALLOWED=NO CURRENT_PROJECT_VERSION="$1" MARKETING_VERSION="$2" build
