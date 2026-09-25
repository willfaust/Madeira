#!/usr/bin/env bash
set -euo pipefail
ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SRC="$ROOT/research/freetype"
OUT="$ROOT/build/freetype-ios/build/libfreetype.a"

if [[ -f "$OUT" ]]; then
  echo "FreeType iOS: cached"
  exit 0
fi

if [[ ! -d "$SRC/.git" ]]; then
  rm -rf "$SRC"
  git clone --depth 1 --branch VER-2-13-3 https://github.com/freetype/freetype.git "$SRC"
fi

"$ROOT/build/freetype-ios/build.sh"
