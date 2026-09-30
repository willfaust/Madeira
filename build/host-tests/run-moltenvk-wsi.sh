#!/bin/bash
# Linux host check; no GPU, Xcode, framework or device is used.
set -euo pipefail
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
"${CC:-cc}" -Wall -Wextra -Werror -g -fsanitize=address,undefined \
    -I"$R/wine/include" "$R/build/host-tests/test_moltenvk_wsi.c" \
    -Wl,--export-dynamic -ldl -o "$TMP/test"
"$TMP/test"
echo "PASS: MoltenVK WSI host lifecycle and Wine ABI contract"
