#!/bin/bash
# Complete DXMT build, shared by the standalone and full IPA workflows.
set -euo pipefail
BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$BUILD_DIR/../.." && pwd)"
APP_PE="$REPO_ROOT/app/Madeira/aarch64-windows"
DXMT_SRC="$REPO_ROOT/research/dxmt"
PATCH_DIR="$REPO_ROOT/patches"
STAMP="$APP_PE/.dxmt-pe-stamp"

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$@"
    else
        shasum -a 256 "$@"
    fi
}

# Local renderer fixes live in patches/ rather than in the submodule, so the
# submodule stays exactly the revision it was tested at and every change to it is
# reviewable as a diff. Apply them before any compilation. A patch that neither
# applies nor is already applied is fatal: silently skipping it would ship DLLs
# without the fix while the build reported success.
apply_dxmt_patches() {
    local patch name
    for patch in "$PATCH_DIR"/dxmt-*.patch; do
        [[ -f "$patch" ]] || continue
        name="$(basename "$patch")"
        if git -C "$DXMT_SRC" apply --check "$patch" 2>/dev/null; then
            echo "Applying DXMT patch: $name"
            git -C "$DXMT_SRC" apply "$patch"
        elif git -C "$DXMT_SRC" apply --reverse --check "$patch" 2>/dev/null; then
            echo "DXMT patch already applied: $name"
        else
            echo "ERROR: DXMT patch does not apply and is not already applied: $name" >&2
            echo "       research/dxmt is at $(git -C "$DXMT_SRC" rev-parse --short HEAD);" >&2
            echo "       rebase the patch onto that revision." >&2
            exit 1
        fi
    done
}

# Hash of the patch set, so the PE rebuild below can tell whether the committed
# DLLs were built from the current patches. Content only: the path sha256sum
# prints differs between a local checkout and a CI runner, and a path-dependent
# stamp would mismatch on every machine and rebuild every run.
dxmt_patch_hash() {
    local patch
    for patch in "$PATCH_DIR"/dxmt-*.patch; do
        [[ -f "$patch" ]] || continue
        sha256_of "$patch" | cut -d' ' -f1
    done | sha256_of | cut -d' ' -f1
}

apply_dxmt_patches
patch_hash="$(dxmt_patch_hash)"

bash "$REPO_ROOT/scripts/prepare-wine-ios.sh"
bash "$BUILD_DIR/build-llvm.sh"
bash "$BUILD_DIR/build.sh"

# The four PE DLLs are committed and shipped with the app, so rebuilding them
# only replaces known-good binaries that were built against the same Wine
# revision with a second opinion -- a needless way to break D3D. Build them when
# they are absent, or when the DXMT patch set no longer matches the one the
# committed DLLs were built from. The stamp is written here and committed
# alongside those DLLs, so a run with unchanged patches skips the rebuild and a
# run with a new fix rebuilds.
rebuild_pe=0
reason=""
# Both architectures ship and Wine loads different ones depending on the
# session: arm64ec-windows for x64 guests (real games) and aarch64-windows
# otherwise. Checking only one directory is exactly how the arm64ec set stayed
# at a revision older than every fix in patches/ without any build noticing.
for arch in aarch64-windows arm64ec-windows; do
    for dll in d3d11 dxgi winemetal d3d10core; do
        if [[ ! -s "$REPO_ROOT/app/Madeira/$arch/$dll.dll" ]]; then
            rebuild_pe=1
            reason="$arch/$dll.dll is missing"
        fi
    done
done
if [[ "$rebuild_pe" == 0 ]]; then
    if [[ ! -f "$STAMP" ]]; then
        rebuild_pe=1
        reason="no build stamp"
    elif [[ "$(cat "$STAMP")" != "$patch_hash" ]]; then
        rebuild_pe=1
        reason="DXMT patches changed since the committed DLLs were built"
    fi
fi

if [[ "$rebuild_pe" == 1 ]]; then
    echo "Rebuilding the DXMT PE DLLs ($reason)."
    bash "$REPO_ROOT/scripts/prepare-wine-ios.sh" --dxmt-pe
    bash "$BUILD_DIR/build-pe.sh"
    echo "$patch_hash" > "$STAMP"
    echo "Wrote $STAMP = $patch_hash"
else
    echo "DXMT PE DLLs match the current patch set -- leaving them alone."
fi
