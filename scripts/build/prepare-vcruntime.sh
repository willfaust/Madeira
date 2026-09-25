#!/usr/bin/env bash
set -euo pipefail
ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
DEST="$ROOT/app/Madeira/x86_64-vcruntime"
CACHE="$ROOT/toolchains/downloads"
EXE="${VC_REDIST_X64:-$CACHE/vc_redist.x64.exe}"
URL="https://aka.ms/vc14/vc_redist.x64.exe"
DLLS=(
  concrt140.dll
  msvcp140.dll
  msvcp140_1.dll
  msvcp140_2.dll
  msvcp140_atomic_wait.dll
  msvcp140_codecvt_ids.dll
  vcamp140.dll
  vccorlib140.dll
  vcomp140.dll
  vcruntime140.dll
  vcruntime140_1.dll
  vcruntime140_threads.dll
)

all_present=1
for dll in "${DLLS[@]}"; do [[ -f "$DEST/$dll" ]] || all_present=0; done
if (( all_present )); then
  echo "Visual C++ runtime: cached"
  exit 0
fi

command -v 7zz >/dev/null || { echo "ERROR: 7zz is required (brew install sevenzip)" >&2; exit 1; }
mkdir -p "$DEST" "$CACHE"

if [[ ! -f "$EXE" ]]; then
  echo "Downloading the official Microsoft Visual C++ x64 Redistributable..."
  curl -fL "$URL" -o "$EXE"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
7zz x -y "$EXE" -o"$TMP/redist" >/dev/null

# The current Microsoft x64 package can also contain ARM64 payloads. Extract all
# CABs, then select only PE32+ AMD64 (Machine 0x8664) DLLs by reading each PE
# header. This keeps the build correct even if Microsoft changes CAB ordering.
CABS=()
while IFS= read -r cab; do CABS+=("$cab"); done < <(find "$TMP/redist" -type f -iname '*.cab' | sort)
(( ${#CABS[@]} > 0 )) || { echo "ERROR: could not locate CAB payloads inside $EXE" >&2; exit 1; }

mkdir -p "$TMP/cabs"
for i in "${!CABS[@]}"; do
  mkdir -p "$TMP/cabs/$i"
  7zz x -y "${CABS[$i]}" -o"$TMP/cabs/$i" >/dev/null || true
done

is_amd64_pe() {
  python3 - "$1" <<'PYPE'
from pathlib import Path
import struct
import sys

p = Path(sys.argv[1])
try:
    data = p.read_bytes()
    if data[:2] != b"MZ" or len(data) < 0x40:
        raise ValueError
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    if data[pe:pe + 4] != b"PE\0\0":
        raise ValueError
    machine = struct.unpack_from("<H", data, pe + 4)[0]
except (OSError, ValueError, struct.error):
    sys.exit(2)

sys.exit(0 if machine == 0x8664 else 1)
PYPE
}

for dll in "${DLLS[@]}"; do
  src=""
  while IFS= read -r candidate; do
    if is_amd64_pe "$candidate"; then
      src="$candidate"
      break
    fi
  done < <(find "$TMP/cabs" -type f -iname "$dll" | sort)
  [[ -n "$src" ]] || { echo "ERROR: x86_64 $dll not found in Microsoft redistributable" >&2; exit 1; }
  cp "$src" "$DEST/$dll"
done

echo "Visual C++ runtime: extracted to $DEST"
