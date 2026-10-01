#!/usr/bin/env bash
# Copy the freshly built GnuTLS stack into app/Madeira/, where the Xcode
# project links it. The repo carries previously built copies of these four
# archives so a plain xcodebuild works, but a clean-clone build must refresh
# them from the toolchain this script chain just compiled.
set -euo pipefail
ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SRC="$ROOT/toolchains/gnutls-ios/lib"
DEST="$ROOT/app/Madeira"
LIBS=(libgmp.a libnettle.a libhogweed.a libgnutls.a)

for lib in "${LIBS[@]}"; do
  [[ -f "$SRC/$lib" ]] || { echo "ERROR: missing $SRC/$lib; run build/gnutls-ios/build.sh first" >&2; exit 1; }
  cp "$SRC/$lib" "$DEST/$lib"
done
echo "GnuTLS libraries: synced to $DEST"
