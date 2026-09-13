#!/bin/sh
# Pre-release gate: run every consistency check that guards a shipped artifact.
#
# Each check here exists because the thing it guards has already shipped broken
# once:
#   - jit-script-sync: the JIT debugger script lives base64-embedded in
#     StikJITHelper.swift and madeira-jit.js is NOT in the Xcode target, so
#     editing the file changes nothing until the literal is regenerated.
#   - check-prefix-template: the prefix template shipped absolute host symlinks
#     that dangle on every device (ml719).
#   - check-xcodeproj: the Xcode project lists every source by hand in four
#     places, so a file that exists but was never registered is silently not
#     part of the program -- the same shape of bug as jit-script-sync, and
#     invisible on any machine that cannot open Xcode.
#   - test-device-capabilities: the JIT pool size is now derived from the
#     device's memory budget, and the override-file parsers are shared by two
#     call sites. Both are pure functions with a table of expected values; the
#     harness only needs swiftc, which a release build has anyway. It skips
#     (exit 0) rather than fails when no toolchain is present.
#   - test-app-ui: same idea for LayoutPolicy. That one comparison is what kept
#     every iPad out of fullscreen, and it is invisible until a device is held.
#   - check-swift-syntax: `swiftc -parse` every app source. The UI is SwiftUI,
#     so nothing in it can be type-checked off a Mac; this at least proves the
#     files parse, which is what a dropped brace costs a build for.
#
# Run from the repo root before tagging/packaging a release. Exits non-zero on
# the first failure.
set -e
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

echo "== JIT script sync =="
tools/jit-script-sync.py

echo "== prefix template =="
tools/check-prefix-template.sh

echo "== xcode project =="
tools/check-xcodeproj.py

echo "== swift syntax =="
tools/check-swift-syntax.sh

echo "== device capabilities =="
tools/test-device-capabilities.sh

echo "== app layout =="
tools/test-app-ui.sh
