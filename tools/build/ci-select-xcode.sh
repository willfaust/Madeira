#!/usr/bin/env bash
# Selects Xcode 27 on a GitHub-hosted macOS runner, so a fork without the
# upstream `xcode-27` runner label can build the IPA (the ntdll unix side uses
# iOS 27 SDK fields). Every job runs this, so all of them pick the same Xcode
# and agree on ci-input-key.sh's fingerprint.
#
#   MADEIRA_XCODE=/Applications/Xcode_27.1.app   use exactly this one
#
# A runner whose selected Xcode is already 27 or later is left as it is.
set -euo pipefail

major() { xcodebuild -version 2>/dev/null | awk '/^Xcode/ { split($2, v, "."); print v[1]; exit }'; }

if [[ -n "${MADEIRA_XCODE:-}" ]]; then
  pick="$MADEIRA_XCODE"
elif [[ "$(major)" -ge 27 ]] 2>/dev/null; then
  echo "Xcode already selected: $(xcode-select -p)"
  xcodebuild -version
  exit 0
else
  # Newest release build first; betas (Xcode_27.0_beta*.app) only when nothing else exists.
  pick=$(ls -d /Applications/Xcode_27*.app 2>/dev/null | grep -vi beta | sort -V | tail -1 || true)
  [[ -n "$pick" ]] || pick=$(ls -d /Applications/Xcode_27*.app /Applications/Xcode-27*.app 2>/dev/null | sort -V | tail -1 || true)
fi

if [[ -z "${pick:-}" || ! -d "$pick" ]]; then
  echo "ERROR: no Xcode 27 on this runner. Installed:" >&2
  ls -d /Applications/Xcode*.app >&2 || true
  echo "Set the repository variable MADEIRA_RUNNER to a runner image that has Xcode 27" >&2
  echo "(Settings > Secrets and variables > Actions > Variables), e.g. macos-26 once it ships Xcode 27," >&2
  echo "or MADEIRA_XCODE to the Xcode app to use." >&2
  exit 1
fi

sudo xcode-select -s "$pick/Contents/Developer"
xcodebuild -version
xcrun --sdk iphoneos --show-sdk-version
