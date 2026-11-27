#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 ft7t8drgwf-wq
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
#
# Applies Madeira's own FEX changes (build/fex-patches/*.patch, in order) to the
# FEX checkout before build/fex-arm64ec/build.sh and build/fex-wow64/build.sh
# build it. The FEX submodule and its repository are not changed: the patches
# only touch the working tree, and a patch already applied is skipped, so both
# build scripts can call this. `apply.sh --revert` takes them out again.
# These patches are Madeira's, not FEX-Emu's: see build/fex-patches/README.md.
set -eu
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
F="$R/FEX"
shopt -s nullglob
patches=("$R"/build/fex-patches/*.patch)
# Nothing to do without patches (and bash 3.2 under set -u rejects "${patches[@]}" when empty).
[ ${#patches[@]} -gt 0 ] || exit 0

# Why a marker file and not just `git apply --reverse --check`.
#
# 2026-11-27: the FEX working tree was found with several patch hunks applied
# THREE to FIVE times (InternalThreadState.h had `GuestDebugRegisters` three
# times, Core.cpp had QueueSMCInvalidate() five times, LookupCache.h had
# GetSharedMap() three times, CPUBackend.h had two stray closing braces). The
# tree did not compile, so no FEX-side fix could be built at all.
#
# The old guard treated "does it reverse-apply?" as "is it applied?". That is
# not a proof for a pure-insertion hunk: after one application the hunk's
# context still matches, so the FORWARD check also succeeds and the next run
# inserts a second copy. Reverse-check keeps succeeding afterwards, so the
# corruption is invisible to the guard forever.
#
# Record the exact patch bytes that were applied. If the recorded digest still
# matches, the patch is applied, full stop -- no context guessing, and no way
# for a later run to stack a second copy on top.
# FEX is a submodule, so .git may be a *file* pointing at the real git dir.
FEX_GITDIR="$(git -C "$F" rev-parse --absolute-git-dir 2>/dev/null || echo "$F/.git")"
STATE="$FEX_GITDIR/madeira-fex-patches-applied"

# shasum ships with macOS, sha256sum with Linux; either is fine for a change marker.
sha256_of() {
    if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
    elif command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
    else cksum "$1" | cut -d' ' -f1-2 | tr ' ' '-'
    fi
}

# Digest recorded for a patch (matched by file name), or empty.
recorded_digest() {
    [ -f "$STATE" ] || return 0
    awk -F: -v name="$1" '$1 == name { sub(/^[^:]*:/, ""); print; exit }' "$STATE" 2>/dev/null || true
}
if [ "${1:-}" = --revert ]; then
    for ((i = ${#patches[@]} - 1; i >= 0; i--)); do
        p="${patches[$i]}"
        if git -C "$F" apply --reverse --check "$p" 2>/dev/null; then
            git -C "$F" apply --reverse "$p"
            echo "fex-patches: reverted $(basename "$p")"
        fi
    done
    rm -f "$STATE"
    exit 0
fi
for p in "${patches[@]}"; do
    name="$(basename "$p")"
    sha="$(sha256_of "$p")"
    recorded="$(recorded_digest "$name")"
    if [ -n "$recorded" ]; then
        if [ "$recorded" = "$sha" ]; then
            echo "fex-patches: $name already applied (recorded)"
            continue
        fi
        # The patch file changed after it was applied. Its new hunk may still
        # pass --check against the already-patched tree and insert a SECOND copy
        # -- the exact defect this guard exists to prevent -- so refuse instead
        # of guessing which version the tree holds.
        echo "fex-patches: $name changed since it was applied (recorded ${recorded:0:12}, now ${sha:0:12}); run --revert and reset the FEX tree" >&2
        exit 1
    elif git -C "$F" apply --reverse --check "$p" 2>/dev/null; then
        echo "fex-patches: $name already applied"
        printf '%s:%s\n' "$name" "$sha" >> "$STATE"
    elif git -C "$F" apply --check "$p" 2>/dev/null; then
        git -C "$F" apply "$p"
        printf '%s:%s\n' "$name" "$sha" >> "$STATE"
        echo "fex-patches: applied $name"
    else
        echo "fex-patches: $name does not apply on FEX $(git -C "$F" rev-parse --short HEAD)" >&2
        exit 1
    fi
done
