#!/usr/bin/env bash
# Package a Mach-O runtime half as a .wcp Madeira can import.
#
#   tools/wcp/make-native-wcp.sh <version-name> <library.dylib> [description]
#   -> dist/<version-name>-native.wcp
#
# This is the channel for the parts of the runtime that are not PE images: the Wine unix
# half (libntdll_unix, libwineserver, libwin32u_unix). In the stock layout those are static
# archives linked into the IPA, so every change to them costs an app rebuild. A package
# built here is imported like any other and takes effect on the next launch, because
# UnixHalf loads it from the component folder before Wine starts.
#
# The library keeps its own file name inside files/: that name is what UnixHalf looks for,
# so a replacement release overwrites the previous one by name and nothing else moves.
set -euo pipefail

VERSION="${1:?usage: make-native-wcp.sh <version-name> <library.dylib> [description]}"
LIB="${2:?missing library.dylib}"
DESC="${3:-Mach-O runtime half for Madeira, loaded at launch instead of linked into the app.}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[ -f "$LIB" ] || { echo "missing $LIB" >&2; exit 1; }
command -v zstd >/dev/null || { echo "zstd is required (brew install zstd)" >&2; exit 1; }

BASE="$(basename "$LIB")"
case "$BASE" in
    *.dylib) ;;
    *) echo "not a Mach-O library: $BASE" >&2; exit 1 ;;
esac
# Mach-O, not a PE that was renamed: check the magic rather than trusting the extension.
# `od` prints the host-endian word without leading zeros, so compare against both forms.
MAGIC="$(od -An -tx4 -N4 "$LIB" | tr -d ' ')"
case "$MAGIC" in
    feedfacf|feedface|cafebabe|cefaedfe|cffaedfe) ;;
    *) echo "not a Mach-O image (magic $MAGIC): $BASE" >&2; exit 1 ;;
esac

OUT="$ROOT/dist"
mkdir -p "$OUT"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Sign before packaging, and sign with the DEVELOPMENT identity, not ad-hoc.
#
# This is not optional tuning: dyld refuses the library without it, and the failure is
# indistinguishable from a dozen other load errors if it is left out. Measured on device
# (build 14, 2026-11-21):
#
#   * unsigned             -> "(missing code signature)"
#   * ad-hoc (`ldid -S`)   -> "code signature invalid"
#   * development identity -> loads, and its `__wine_unixlib_handle` resolves
#
# LiveContainer re-signs the guest app bundle with its own identity, which is this
# project's own team (4CDWTGR84Z), so a library signed with the same development
# certificate passes team validation. Ad-hoc has no team at all, which is why signing
# it "somehow" looked like it should work and did not.
IDENTITY="${MADEIRA_SIGN_IDENTITY:-Apple Development: austinturner859@gmail.com (46R7UQ723P)}"
if ! security find-identity -v -p codesigning 2>/dev/null | grep -qF "$IDENTITY"; then
    echo "signing identity not found: $IDENTITY" >&2
    echo "available identities:" >&2
    security find-identity -v -p codesigning 2>&1 | sed 's/^/  /' >&2
    echo "set MADEIRA_SIGN_IDENTITY to override" >&2
    exit 1
fi

mkdir -p "$WORK/files"
cp "$LIB" "$WORK/files/$BASE"
codesign -f -s "$IDENTITY" "$WORK/files/$BASE" || {
    echo "codesign failed for $BASE" >&2
    exit 1
}
# Prove the team is the one LiveContainer uses, rather than trusting the command above.
TEAM="$(codesign -dvvv "$WORK/files/$BASE" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
[ -n "$TEAM" ] || { echo "signed but has no TeamIdentifier: $BASE" >&2; exit 1; }

cat > "$WORK/profile.json" <<EOF
{
  "type": "UnixHalf",
  "versionName": "$VERSION",
  "versionCode": 1,
  "description": "$DESC",
  "files": [
    {
      "source": "files/$BASE",
      "target": "files/$BASE"
    }
  ]
}
EOF

DEST="$OUT/$VERSION-native.wcp"
( cd "$WORK" && COPYFILE_DISABLE=1 tar --disable-copyfile -cf - profile.json files ) | zstd -q -f -19 -o "$DEST"
printf '%s  (%s, %s, team %s)\n' "$DEST" "$BASE" "$(du -h "$DEST" | cut -f1)" "$TEAM"
