#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WINE="$ROOT/wine"
PATCH="$ROOT/patches/wine-opengl-winios.patch"

if git -C "$WINE" apply --reverse --check "$PATCH" 2>/dev/null; then
    exit 0
fi
git -C "$WINE" apply --check "$PATCH"
git -C "$WINE" apply "$PATCH"
