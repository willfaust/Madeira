#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
#
# ml2320: build epic_parent.c as a stripped x86-64 GUI program and install it as
#   app/Madeira/arm64ec-windows/EpicGamesLauncher.exe
# (C:\windows\system32\EpicGamesLauncher.exe in every prefix), committed like the farm's
# other builtins. A GUI program, so starting it opens no console. x86-64, so it runs in
# both a 64-bit x86 session and the Wine desktop, like the x64 games it starts.
# LLVM_MINGW=<dir with x86_64-w64-mingw32-clang> overrides the toolchain.
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$DIR/../.." && pwd)"
MINGW="${LLVM_MINGW:-$REPO_ROOT/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin}"
CC="$MINGW/x86_64-w64-mingw32-clang"
DEST="${DEST:-$REPO_ROOT/app/Madeira/arm64ec-windows}"
[ -x "$CC" ] || { echo "missing cross compiler: $CC (set LLVM_MINGW)" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
"$CC" -std=c11 -O2 -Wall -Wextra -Werror -municode -mwindows \
    -Wl,--strip-all -Wl,--no-insert-timestamp \
    -o "$TMP/EpicGamesLauncher.exe" "$DIR/epic_parent.c"

mkdir -p "$DEST"
cp "$TMP/EpicGamesLauncher.exe" "$DEST/EpicGamesLauncher.exe"
echo "EpicGamesLauncher.exe: $(wc -c < "$DEST/EpicGamesLauncher.exe" | tr -d ' ') bytes -> $DEST"
