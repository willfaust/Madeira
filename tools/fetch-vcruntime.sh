#!/bin/bash
set -euo pipefail

R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$R/app/Madeira/x86_64-vcruntime"
URL="https://aka.ms/vs/17/release/vc_redist.x64.exe"
TMP="$(mktemp -d /tmp/madeira-vcrt.XXXXXX 2>/dev/null || mktemp -d)"

trap 'rm -rf "$TMP"' EXIT

mkdir -p "$DEST"

echo "fetching VC_redist.x64.exe..."
curl -fL --retry 3 -o "$TMP/VC_redist.x64.exe" "$URL"

SEVENZIP=""
if command -v 7zz >/dev/null 2>&1; then
    SEVENZIP="7zz"
elif command -v 7z >/dev/null 2>&1; then
    SEVENZIP="7z"
else
    echo "7zz or 7z not found, brew install sevenzip" >&2
    exit 1
fi

"$SEVENZIP" x "$TMP/VC_redist.x64.exe" -o"$TMP/ext" -y >/dev/null

CABS=$(find "$TMP/ext" -type f -name "*.cab" 2>/dev/null || true)
if [ -z "$CABS" ]; then
    echo "failed to find cab files in installer" >&2
    exit 1
fi

mkdir -p "$TMP/cab_out"
for cab in $CABS; do
    "$SEVENZIP" e "$cab" -o"$TMP/cab_out" -y >/dev/null 2>&1 || true
done

WANTED=(
    "concrt140.dll"
    "msvcp140.dll"
    "msvcp140_1.dll"
    "msvcp140_2.dll"
    "msvcp140_atomic_wait.dll"
    "msvcp140_codecvt_ids.dll"
    "vcamp140.dll"
    "vccorlib140.dll"
    "vcomp140.dll"
    "vcruntime140.dll"
    "vcruntime140_1.dll"
    "vcruntime140_threads.dll"
)

FOUND=0
for name in "${WANTED[@]}"; do
    MATCH=$(find "$TMP/cab_out" -type f -iname "$name" | head -n 1 || true)
    if [ -n "$MATCH" ] && [ -f "$MATCH" ]; then
        cp "$MATCH" "$DEST/$name"
        FOUND=$((FOUND + 1))
    fi
done

echo "$FOUND/${#WANTED[@]} runtime files copied to $DEST"

python3 "$R/tests/host/check-vcruntime.py"
