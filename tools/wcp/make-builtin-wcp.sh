#!/usr/bin/env bash
# Package one or more PE builtins so an import replaces the bundle's own copies.
#
#   tools/wcp/make-builtin-wcp.sh <version-name> <dll> [<dll> ...]
#   -> dist/<version-name>-builtin.wcp
#
# Why this exists: `ntdll.dll` is loaded by Wine's loader from `WINEDLLPATH`, which the app
# sets to its own bundle (`app/Madeira/arm64ec-windows/`). Every other Wine piece already
# ships as a component — the unix half as a dylib (`UnixHalf`) and FEX as `xtajit64.dll` —
# but a PE builtin change used to mean rebuilding and reinstalling the app. A package of this
# kind installs into `Documents/Components/<id>/pe/arm64ec-windows/`, and the app puts that
# directory in front of the bundle on `WINEDLLPATH`, so the import wins. Nothing in the bundle
# or the code signature changes, and switching the component off restores the bundle's copy.
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
    cp "$dll" "$WORK/files/lib/wine/arm64ec-windows/$base"
    FILES="$FILES${FILES:+,}
    {
      \"source\": \"files/lib/wine/arm64ec-windows/$base\",
      \"target\": \"\${system32}/$base\"
    }"
done

cat > "$WORK/profile.json" <<EOF
{
  "type": "Wine-Builtin",
  "versionName": "$VERSION",
  "versionCode": 1,
  "description": "Wine PE builtins for Madeira, installed ahead of the app bundle on the loader's DLL path.",
  "files": [$FILES]
}
EOF

DEST="$OUT/$VERSION-builtin.wcp"
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
        names = [n for n in tf.getnames() if n.endswith(".dll")]
    print(f"  type={p['type']} version={p['versionName']} dlls={names}")
PY
