#!/usr/bin/env bash
set -euo pipefail
ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
DEST="$ROOT/app/Madeira/x86_64-vcruntime"
CACHE="$ROOT/toolchains/downloads"
EXE="${VC_REDIST_X64:-$CACHE/vc_redist.x64.exe}"
URL="https://aka.ms/vs/17/release/vc_redist.x64.exe"
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

SEVENZIP=""
if command -v 7zz >/dev/null 2>&1; then
  SEVENZIP="7zz"
elif command -v 7z >/dev/null 2>&1; then
  SEVENZIP="7z"
elif command -v brew >/dev/null 2>&1 && [[ -x "$(brew --prefix sevenzip 2>/dev/null || true)/bin/7zz" ]]; then
  SEVENZIP="$(brew --prefix sevenzip)/bin/7zz"
elif [[ -x "/opt/homebrew/bin/7zz" ]]; then
  SEVENZIP="/opt/homebrew/bin/7zz"
elif [[ -x "/usr/local/bin/7zz" ]]; then
  SEVENZIP="/usr/local/bin/7zz"
else
  echo "ERROR: 7zz or 7z is required (brew install sevenzip)" >&2
  exit 1
fi

mkdir -p "$DEST" "$CACHE"

# Validate or re-download executable. Remove partial/corrupt downloads.
validate_exe() {
  [[ -f "$1" && -s "$1" ]] && "$SEVENZIP" t "$1" >/dev/null 2>&1
}

if ! validate_exe "$EXE"; then
  echo "Downloading the official Microsoft Visual C++ x64 Redistributable..."
  rm -f "$EXE"
  curl --fail --location --retry 3 --retry-all-errors -o "$EXE" "$URL"
  if ! validate_exe "$EXE"; then
    echo "ERROR: Downloaded $EXE is invalid or corrupt" >&2
    exit 1
  fi
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

EXTRACT_DIR="$TMP/redist"
mkdir -p "$EXTRACT_DIR"
"$SEVENZIP" x -y "$EXE" -o"$EXTRACT_DIR" >/dev/null

# Extract the bootstrapper and search recursively for CAB payloads.
# In case nested executables/installers contain the CABs, extract them as well.
while true; do
  nested_found=0
  while IFS= read -r nested; do
    nested_dir="${nested}_extracted"
    if [[ ! -d "$nested_dir" ]]; then
      mkdir -p "$nested_dir"
      if "$SEVENZIP" x -y "$nested" -o"$nested_dir" >/dev/null 2>&1; then
        nested_found=1
      fi
    fi
  done < <(find "$EXTRACT_DIR" -type f \( -iname '*.exe' -o -iname '*.msi' \) | sort)
  (( nested_found == 0 )) && break
done

# 1. First, check if 7-Zip directly extracted any of the required DLLs or dll_amd64 files
copy_matching_dlls() {
  local search_dir="$1"
  local found=0
  for dll in "${DLLS[@]}"; do
    if [[ ! -f "$DEST/$dll" ]]; then
      local candidate=""
      candidate="$(find "$search_dir" -type f \( -iname "$dll" -o -iname "${dll}_amd64" \) 2>/dev/null | head -n 1 || true)"
      if [[ -n "$candidate" ]]; then
        cp "$candidate" "$DEST/$dll"
        echo "  Extracted $dll from $candidate"
      fi
    fi
  done
}

copy_matching_dlls "$EXTRACT_DIR"

# 2. Check if all DLLs are already satisfied from direct extraction
all_found=1
for dll in "${DLLS[@]}"; do [[ -f "$DEST/$dll" ]] || all_found=0; done

if (( ! all_found )); then
  # Extract any CAB files found in the extraction tree
  CABS=()
  while IFS= read -r cab; do CABS+=("$cab"); done < <(find "$EXTRACT_DIR" -type f -iname '*.cab' 2>/dev/null | sort)

  # If no .cab files exist by extension, carve embedded MSCF CAB streams out of the EXE
  if (( ${#CABS[@]} == 0 )); then
    echo "Carving embedded CAB streams from $EXE..."
    python3 - "$EXE" "$TMP" <<'PYCARVE'
import sys, os, struct

exe_path = sys.argv[1]
out_dir = sys.argv[2]
with open(exe_path, "rb") as f:
    data = f.read()

idx = 0
cab_idx = 0
while True:
    pos = data.find(b"MSCF", idx)
    if pos == -1:
        break
    if pos + 32 <= len(data):
        try:
            sig, _, cbCab = struct.unpack_from("<4sII", data, pos)
            if sig == b"MSCF" and 32 < cbCab <= len(data) - pos:
                cab_file = os.path.join(out_dir, f"embedded_{cab_idx}.cab")
                with open(cab_file, "wb") as out:
                    out.write(data[pos : pos + cbCab])
                print(f"  Carved {cab_file} ({cbCab} bytes at offset {pos})")
                cab_idx += 1
        except Exception:
            pass
    idx = pos + 4
PYCARVE
    while IFS= read -r cab; do CABS+=("$cab"); done < <(find "$TMP" -maxdepth 1 -type f -iname '*.cab' 2>/dev/null | sort)
  fi

  # Recursively extract each discovered or carved CAB
  mkdir -p "$TMP/cabs"
  for i in "${!CABS[@]}"; do
    cab_dest="$TMP/cabs/$i"
    mkdir -p "$cab_dest"
    "$SEVENZIP" x -y "${CABS[$i]}" -o"$cab_dest" >/dev/null 2>&1 || true
    while IFS= read -r inner_cab; do
      is_cab=0
      if [[ "$inner_cab" == *.cab ]]; then
        is_cab=1
      elif [[ $(head -c 4 "$inner_cab" 2>/dev/null) == "MSCF" ]]; then
        is_cab=1
      fi
      if (( is_cab )); then
        inner_dest="${inner_cab}_extracted"
        mkdir -p "$inner_dest"
        "$SEVENZIP" x -y "$inner_cab" -o"$inner_dest" >/dev/null 2>&1 || true
      fi
    done < <(find "$cab_dest" -type f 2>/dev/null || true)
  done

  copy_matching_dlls "$TMP/cabs"
fi

missing=()
for dll in "${DLLS[@]}"; do
  if [[ ! -f "$DEST/$dll" ]]; then
    missing+=("$dll")
  fi
done

if (( ${#missing[@]} > 0 )); then
  echo "ERROR: The following required x86_64 Visual C++ runtime DLLs were not found: ${missing[*]}" >&2
  exit 1
fi

echo "Visual C++ runtime: extracted to $DEST"
