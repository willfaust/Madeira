#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 ft7t8drgwf-wq
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
#
# Applies this repository's DXMT changes (build/dxmt-patches/*.patch, in
# order) to the dxmt checkout before build/dxmt-ios/build.sh, build/wine-i386/build.sh and build/windows-runtime/build.sh build DXMT.
# The dxmt submodule and its repository are not changed: the patches only
# touch the working tree, and a patch already applied is skipped, so every
# build script can call this. `apply.sh --revert` takes them out again.
# See build/dxmt-patches/README.md.
set -eu
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
S="$R/dxmt"
shopt -s nullglob
patches=("$R"/build/dxmt-patches/*.patch)
# Nothing to do without patches (and bash 3.2 under set -u rejects "${patches[@]}" when empty).
[ ${#patches[@]} -gt 0 ] || exit 0
if [ "${1:-}" = --revert ]; then
    for ((i = ${#patches[@]} - 1; i >= 0; i--)); do
        p="${patches[$i]}"
        if git -C "$S" apply --reverse --check "$p" 2>/dev/null; then
            git -C "$S" apply --reverse "$p"
            echo "dxmt-patches: reverted $(basename "$p")"
        fi
    done
    exit 0
fi
for p in "${patches[@]}"; do
    if git -C "$S" apply --reverse --check "$p" 2>/dev/null; then
        echo "dxmt-patches: $(basename "$p") already applied"
    elif git -C "$S" apply --check "$p" 2>/dev/null; then
        git -C "$S" apply "$p"
        echo "dxmt-patches: applied $(basename "$p")"
    else
        echo "dxmt-patches: $(basename "$p") does not apply on dxmt $(git -C "$S" rev-parse --short HEAD)" >&2
        exit 1
    fi
done
