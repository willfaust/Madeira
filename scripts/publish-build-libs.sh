#!/bin/bash
# Publish the prebuilt archives Madeira.app links against, so CI can restore them.
#
# Run this ONCE on a Mac whose tree already builds the app. It is the missing
# half of the IPA workflow: most of what the link step needs (FEX, wineserver /
# ntdll / win32u, DXMT) is gitignored, and the submodules they come from are
# empty in a clean clone, so a GitHub-hosted runner sees 11 of 15 archives
# missing and cannot link at all.
#
# Publishing them as a release asset makes .github/workflows/ipa.yml work on an
# ordinary macOS runner. Without it, that workflow only runs on a self-hosted
# machine that already has the tree built.
#
# The asset is a build product, not source: it is tied to the toolchain and
# commit that produced it. Re-publish when any of those change, or the IPA will
# link a stale core against new app code.
#
# Usage:
#   scripts/publish-build-libs.sh [--tag TAG] [--repo OWNER/REPO] [--no-upload]
#
# Defaults: tag `build-libs`, repo taken from the `fork` remote then `origin`.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

TAG="build-libs"
REPO=""
UPLOAD=1
ASSET="madeira-build-libs.tar.gz"

while [ $# -gt 0 ]; do
    case "$1" in
        --tag)       TAG="$2"; shift 2 ;;
        --repo)      REPO="$2"; shift 2 ;;
        --no-upload) UPLOAD=0; shift ;;
        -h|--help)   sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

# Ask the gate for the list rather than keeping a second copy of it here.
echo "==> Collecting required archives"
LIST=$(tools/check-build-inputs.sh --list)
MISSING=0
while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ ! -f "$f" ]; then
        echo "  missing: $f" >&2
        MISSING=1
    fi
done <<< "$LIST"
if [ "$MISSING" -ne 0 ]; then
    echo "" >&2
    echo "publish-build-libs: this tree does not have everything the app links." >&2
    echo "  Build it first: the FEX and DXMT pieces come from their own builds," >&2
    echo "  see build/dxmt-ios/README.md. Nothing here can invent them." >&2
    exit 1
fi

COUNT=$(wc -l <<< "$LIST" | tr -d ' ')
echo "==> Packing $COUNT archives into $ASSET"
# Paths are repo-relative, so a restore from the repo root puts each archive
# back where the Xcode project looks for it.
rm -f "$ASSET"
tar czf "$ASSET" -T <(printf '%s\n' "$LIST")
echo "    $(du -h "$ASSET" | awk '{print $1}')"

if [ "$UPLOAD" -eq 0 ]; then
    echo ""
    echo "==> Not uploading (--no-upload). Asset is at $ROOT/$ASSET"
    echo "    Upload it yourself as a release asset named exactly '$ASSET'."
    exit 0
fi

if ! command -v gh >/dev/null 2>&1; then
    echo ""
    echo "publish-build-libs: gh not found, so nothing was uploaded." >&2
    echo "  Asset is at $ROOT/$ASSET -- upload it as a release asset named" >&2
    echo "  exactly '$ASSET' on tag '$TAG', or install gh and re-run." >&2
    exit 1
fi

if [ -z "$REPO" ]; then
    for remote in fork origin; do
        url=$(git remote get-url "$remote" 2>/dev/null || true)
        case "$url" in
            *github.com[:/]*)
                REPO=$(printf '%s' "$url" \
                    | sed -E 's#.*github\.com[:/]##; s#\.git$##')
                echo "==> Using repo from '$remote' remote: $REPO"
                break
                ;;
        esac
    done
fi
[ -n "$REPO" ] || { echo "publish-build-libs: no GitHub remote; pass --repo OWNER/REPO" >&2; exit 1; }

echo "==> Uploading to $REPO release '$TAG'"
# Create the release if it is not there yet; --clobber replaces the asset on a
# re-publish, which is the normal case once the core changes.
if ! gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    gh release create "$TAG" --repo "$REPO" \
        --title "Prebuilt libraries for CI" \
        --notes "Build products the Xcode link step needs. Not source; re-publish when the toolchain or core commit changes."
fi
gh release upload "$TAG" "$ASSET" --repo "$REPO" --clobber

echo ""
echo "==> Done"
echo "    $REPO release '$TAG' now has $ASSET ($COUNT archives)."
echo "    .github/workflows/ipa.yml will restore it on the next dispatch."
