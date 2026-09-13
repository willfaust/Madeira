#!/bin/sh
# Syntax-check every Swift file in the app.
#
# `swiftc -parse` parses without resolving imports, so it runs on a Linux box
# with no iOS SDK and still catches the class of mistake that matters most here:
# the whole UI is SwiftUI, so nothing in ContentView.swift can be type-checked
# off a Mac, and a stray brace used to be invisible until the build broke on
# someone's laptop.
#
# It is NOT a type-check. A typo'd property name still compiles here and fails
# in Xcode. It only proves the files parse.
#
# Needs a Swift toolchain: Xcode's swiftc on macOS, or any swiftc on Linux.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

SWIFTC=${SWIFTC:-swiftc}
if ! command -v "$SWIFTC" >/dev/null 2>&1; then
    echo "check-swift-syntax: SKIP -- no swiftc on PATH (override with SWIFTC=...)" >&2
    exit 0
fi

# shellcheck disable=SC2046
set -- $(find app/Madeira -name '*.swift' | sort)
if [ "$#" -eq 0 ]; then
    echo "check-swift-syntax: FAIL -- no Swift files found under app/Madeira"
    exit 1
fi

if ! "$SWIFTC" -parse "$@" 2>&1; then
    echo "check-swift-syntax: FAIL -- parse errors above ($# files)"
    exit 1
fi

echo "check-swift-syntax: OK -- $# files parse"
