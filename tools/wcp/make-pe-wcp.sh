#!/usr/bin/env bash
# Package PE builtins so they REPLACE the bundle's copies inside the Wine prefix.
#
#   tools/wcp/make-pe-wcp.sh <version-name> <dll> [<dll> ...]
#   -> dist/<version-name>-pe.wcp
#
# This is the DroidDeck-equivalent channel: a component of kind `Wine` is linked into
# drive_c/windows/system32/<name> by WineProcessBridge.m (`madeira_apply_wcp_components`),
# after the bundle's own links are laid down, so the package wins for that session.
# Disable it and the next launch re-links the bundle's copy: nothing in the app bundle
# changes, nothing is re-signed, nothing is reinstalled.
#
# Use make-builtin-wcp.sh instead for `ntdll.dll` only, because the loader builds ntdll's
# path from the bundle directory directly and never resolves it through the prefix.
set -euo pipefail

VERSION="${1:-}"
[ -n "$VERSION" ] || { echo "usage: $0 <version-name> <dll> [<dll> ...]" >&2; exit 2; }
shift || true
[ "$#" -gt 0 ] || { echo "missing a .dll to package" >&2; exit 2; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
command -v zstd >/dev/null || { echo "zstd is required (brew install zstd)" >&2; exit 1; }

OUT="$ROOT/dist"
mkdir -p "$OUT"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/files/lib/wine/arm64ec-windows"

FILES=""
for dll in "$@"; do
    [ -f "$dll" ] || { echo "missing $dll" >&2; exit 1; }
    base="$(basename "$dll")"
    # The `.` and `${}` in the target are resolved by the bridge, not the shell.
    cp "$dll" "$WORK/files/lib/wine/arm64ec-windows/$base"
    FILES="$FILES${FILES:+,}
    {
      \"source\": \"files/lib/wine/arm64ec-windows/$base\",
      \"target\": \"\${system32}/$base\"
    }"
done

cat > "$WORK/profile.json" <<EOF
{
  "type": "Wine",
  "versionName": "$VERSION",
  "versionCode": 1,
  "description": "Wine PE builtins for Madeira, linked over the app bundle's copies in drive_c/windows/system32 for the session that has this package enabled.",
  "files": [$FILES]
}
EOF

DEST="$OUT/$VERSION-pe.wcp"
# COPYFILE_DISABLE: macOS tar otherwise adds `._name` AppleDouble members, which the installer
# would copy in as extra (useless) DLLs next to the real ones.
( cd "$WORK" && COPYFILE_DISABLE=1 tar --disable-copyfile -cf - profile.json files ) | zstd -q -f -19 -o "$DEST"
printf '%s  (%s)\n' "$DEST" "$(du -h "$DEST" | cut -f1)"
python3 - "$DEST" <<'PY'
import json, subprocess, sys, tarfile, tempfile, os
d = sys.argv[1]
with tempfile.TemporaryDirectory() as t:
    raw = os.path.join(t, "a.tar")
    subprocess.run(["zstd","-q","-d","-o",raw,d], check=True)
    with tarfile.open(raw) as tf:
        p = json.load(tf.extractfile("profile.json"))
        dlls = [n.split("/")[-1] for n in tf.getnames() if n.endswith(".dll")]
    print(f"  type={p['type']} version={p['versionName']} dlls={dlls}")
PY
