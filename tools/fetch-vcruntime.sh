#!/bin/bash
# Obtain unmodified Microsoft x64 runtime DLLs for this local build.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${VCRUNTIME_OUT:-$REPO_ROOT/app/Madeira/x86_64-vcruntime}"
URL="${VCRUNTIME_URL:-https://aka.ms/vs/17/release/vc_redist.x64.exe}"

command -v python3 >/dev/null || { echo "Install Python 3 first." >&2; exit 1; }
SEVEN=""
for candidate in 7zz 7z; do
  if command -v "$candidate" >/dev/null; then SEVEN="$candidate"; break; fi
done
if [[ -z "$SEVEN" ]]; then
  echo "Install 7-Zip first (macOS: brew install sevenzip)." >&2
  exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/madeira-vcruntime.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
INSTALLER="${VCRUNTIME_INSTALLER:-}"
if [[ -z "$INSTALLER" ]]; then
  command -v curl >/dev/null || { echo "Install curl first." >&2; exit 1; }
  INSTALLER="$WORK/VC_redist.x64.exe"
  echo "Downloading Microsoft Visual C++ x64 redistributable..."
  # Do not echo the URL: CI may supply an authenticated URL through a secret.
  curl --fail --silent --show-error --location --retry 3 \
    --connect-timeout 30 --max-time 300 --proto '=https' --proto-redir '=https' \
    --output "$INSTALLER" "$URL"
fi

python3 "$REPO_ROOT/tools/extract-vcruntime.py" "$INSTALLER" "$OUT" --sevenzip "$SEVEN"
